package httpapi

import (
	"bytes"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	viewerweb "github.com/tomas-lejdung/Clip/server/web"
)

func TestViewerPageIsStaticNoStoreAndUsesIsolatedSecurityPolicy(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	var firstBody []byte
	for index, roomCode := range []string{"ROOM2WEB", "WEB2ROOM"} {
		response, err := http.Get(server.URL + "/" + roomCode)
		if err != nil {
			t.Fatal(err)
		}
		body, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		faviconLink := []byte(
			`rel="icon" type="image/png" sizes="64x64" ` +
				`href="/assets/clip-favicon.png"`,
		)
		if response.StatusCode != http.StatusOK ||
			response.Header.Get("Content-Type") != "text/html; charset=utf-8" ||
			response.Header.Get("Cache-Control") != "no-store" ||
			!bytes.Contains(body, []byte("clip-viewer.js")) ||
			!bytes.Contains(body, faviconLink) {
			t.Fatalf("viewer response = %d, %#v, %d bytes", response.StatusCode, response.Header, len(body))
		}
		csp := response.Header.Get("Content-Security-Policy")
		for _, required := range []string{
			"default-src 'none'",
			"script-src 'self'",
			"style-src 'self'",
			"connect-src 'self'",
			"media-src 'self' blob:",
			"frame-ancestors 'none'",
		} {
			if !strings.Contains(csp, required) {
				t.Fatalf("viewer CSP %q is missing %q", csp, required)
			}
		}
		if strings.Contains(csp, "unsafe-inline") ||
			strings.Contains(csp, "unsafe-eval") ||
			response.Header.Get("Cross-Origin-Opener-Policy") != "same-origin" ||
			response.Header.Get("Cross-Origin-Resource-Policy") != "same-origin" ||
			!strings.Contains(response.Header.Get("Permissions-Policy"), "camera=()") ||
			!strings.Contains(response.Header.Get("Permissions-Policy"), "microphone=()") ||
			!strings.Contains(response.Header.Get("Permissions-Policy"), "display-capture=()") {
			t.Fatalf("viewer security headers = %#v", response.Header)
		}
		if index == 0 {
			firstBody = body
		} else if !bytes.Equal(firstBody, body) {
			t.Fatal("room code was injected into the static viewer document")
		}
	}
}

func TestViewerCSPNeverReflectsAnInvalidHost(t *testing.T) {
	t.Parallel()
	service, err := New(testConfiguration())
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	request := httptest.NewRequest(http.MethodGet, "http://clip.test/ROOM2WEB", nil)
	request.Host = "clip.test; script-src *"
	recorder := httptest.NewRecorder()
	service.Handler().ServeHTTP(recorder, request)
	csp := recorder.Header().Get("Content-Security-Policy")
	if recorder.Code != http.StatusOK || strings.Contains(csp, request.Host) ||
		strings.Contains(csp, "script-src *") ||
		!strings.Contains(csp, "connect-src 'self'") {
		t.Fatalf("host-injection CSP = %d, %q", recorder.Code, csp)
	}
}

func TestViewerPageRejectsNonCanonicalAndInvalidRoomPaths(t *testing.T) {
	t.Parallel()
	service, err := New(testConfiguration())
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	for _, target := range []string{
		"http://clip.test/SHORT",
		"http://clip.test/TOOLONG99",
		"http://clip.test/BAD-CODE",
		"http://clip.test/BAD_CODE",
		"http://clip.test/room2web",
		"http://clip.test/ROOM2WEB/extra",
		"http://clip.test/ROOM2WEB?tracking=1",
		"http://clip.test/%52OOM2WEB",
	} {
		request := httptest.NewRequest(http.MethodGet, target, nil)
		recorder := httptest.NewRecorder()
		service.Handler().ServeHTTP(recorder, request)
		if recorder.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d; want 404", target, recorder.Code)
		}
	}
}

func TestViewerAssetsAreEmbeddedAllowlistedAndRevalidated(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	for asset := range viewerAssets {
		response, err := http.Get(server.URL + "/assets/" + asset)
		if err != nil {
			t.Fatal(err)
		}
		body, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		if response.StatusCode != http.StatusOK || len(body) == 0 ||
			response.Header.Get("Cache-Control") != "public, max-age=0, must-revalidate" ||
			response.Header.Get("ETag") == "" ||
			response.Header.Get("Cross-Origin-Resource-Policy") != "same-origin" {
			t.Fatalf("asset %s response = %d, %#v, %d bytes", asset, response.StatusCode, response.Header, len(body))
		}
		contentType := response.Header.Get("Content-Type")
		if strings.HasSuffix(asset, ".css") {
			if contentType != "text/css; charset=utf-8" {
				t.Fatalf("CSS type = %q", contentType)
			}
		} else if strings.HasSuffix(asset, ".png") {
			if contentType != "image/png" {
				t.Fatalf("PNG type = %q", contentType)
			}
		} else if contentType != "text/javascript; charset=utf-8" {
			t.Fatalf("JavaScript type = %q", contentType)
		}

		request, err := http.NewRequest(http.MethodGet, server.URL+"/assets/"+asset, nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("If-None-Match", response.Header.Get("ETag"))
		revalidated, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		revalidatedBody, readErr := io.ReadAll(revalidated.Body)
		revalidated.Body.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		if revalidated.StatusCode != http.StatusNotModified || len(revalidatedBody) != 0 {
			t.Fatalf("asset %s revalidation = %d, %d bytes", asset, revalidated.StatusCode, len(revalidatedBody))
		}
	}
}

func TestViewerFaviconMatchesCheckedInAppIcon(t *testing.T) {
	t.Parallel()
	embedded, err := fs.ReadFile(viewerweb.Assets, viewerAssets["clip-favicon.png"])
	if err != nil {
		t.Fatal(err)
	}
	appIconPath := filepath.Join(
		"..", "..", "..", "Clip", "Resources", "Assets.xcassets",
		"AppIcon.appiconset", "ClipAppIcon-64.png",
	)
	appIcon, err := os.ReadFile(appIconPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(embedded, appIcon) {
		t.Fatal("embedded Web favicon differs from ClipAppIcon-64.png")
	}
}

func TestEveryEmbeddedViewerAssetIsExplicitlyAllowlisted(t *testing.T) {
	t.Parallel()
	entries, err := fs.ReadDir(viewerweb.Assets, "assets")
	if err != nil {
		t.Fatal(err)
	}
	allowlisted := make(map[string]bool, len(viewerAssets))
	for publicName, embeddedPath := range viewerAssets {
		if filepath.Base(embeddedPath) != publicName {
			t.Fatalf("viewer asset %q maps to unexpected path %q", publicName, embeddedPath)
		}
		allowlisted[embeddedPath] = true
	}
	for _, entry := range entries {
		if entry.IsDir() {
			t.Fatalf("unexpected embedded viewer directory: %s", entry.Name())
		}
		embeddedPath := "assets/" + entry.Name()
		if !allowlisted[embeddedPath] {
			t.Fatalf("embedded viewer asset is not HTTP allowlisted: %s", embeddedPath)
		}
		delete(allowlisted, embeddedPath)
	}
	if len(allowlisted) != 0 {
		t.Fatalf("allowlisted viewer assets are not embedded: %#v", allowlisted)
	}
}

func TestViewerRoutesHonorHeadAndRejectMutatingMethods(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	for _, target := range []string{
		"/ROOM2WEB",
		"/assets/clip-viewer.js",
	} {
		request, err := http.NewRequest(http.MethodHead, server.URL+target, nil)
		if err != nil {
			t.Fatal(err)
		}
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		body, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil {
			t.Fatal(readErr)
		}
		if response.StatusCode != http.StatusOK || len(body) != 0 {
			t.Fatalf("HEAD %s = %d, %d bytes", target, response.StatusCode, len(body))
		}

		request, err = http.NewRequest(http.MethodPost, server.URL+target, strings.NewReader("ignored"))
		if err != nil {
			t.Fatal(err)
		}
		response, err = http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusMethodNotAllowed ||
			!strings.Contains(response.Header.Get("Allow"), http.MethodGet) {
			t.Fatalf("POST %s = %d, Allow %q", target, response.StatusCode, response.Header.Get("Allow"))
		}
	}
}

func TestViewerAssetTraversalAndUnlistedFilesAreNeverServed(t *testing.T) {
	t.Parallel()
	service, err := New(testConfiguration())
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	for _, target := range []string{
		"http://clip.test/assets/viewer.html",
		"http://clip.test/assets/unknown.js",
		"http://clip.test/assets/clip-viewer.js.map",
		"http://clip.test/assets/nested/clip-viewer.js",
		"http://clip.test/assets/../version",
		"http://clip.test/assets/%2e%2e/version",
		"http://clip.test/assets//clip-viewer.js",
		"http://clip.test/assets/clip%2dviewer.js",
	} {
		request := httptest.NewRequest(http.MethodGet, target, nil)
		recorder := httptest.NewRecorder()
		service.Handler().ServeHTTP(recorder, request)
		if recorder.Code != http.StatusNotFound {
			t.Fatalf("%s status = %d; want 404", target, recorder.Code)
		}
	}
}

func TestNativeAPIKeepsNonExecutableSecurityPolicy(t *testing.T) {
	t.Parallel()
	_, server := newHTTPTestServer(t)
	response, err := http.Get(server.URL + "/api/native/v4/rooms/invalid")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	csp := response.Header.Get("Content-Security-Policy")
	if csp != "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" ||
		strings.Contains(csp, "script-src") || strings.Contains(csp, "connect-src") {
		t.Fatalf("native API CSP changed to viewer policy: %q", csp)
	}
}
