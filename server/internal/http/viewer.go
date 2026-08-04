package httpapi

import (
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"net/http"
	"path"
	"strings"

	viewerweb "github.com/tomas-lejdung/Clip/server/web"
)

const (
	viewerRoomCodeLength = 8
	viewerPagePath       = "viewer.html"
)

var viewerAssets = map[string]string{
	"clip-viewer.js":          "assets/clip-viewer.js",
	"clip-viewer.css":         "assets/clip-viewer.css",
	"clip-room-crypto.js":     "assets/clip-room-crypto.js",
	"clip-room-session.js":    "assets/clip-room-session.js",
	"clip-mesh-peer.js":       "assets/clip-mesh-peer.js",
	"clip-media-store.js":     "assets/clip-media-store.js",
	"clip-serial-queue.js":    "assets/clip-serial-queue.js",
	"clip-web-diagnostics.js": "assets/clip-web-diagnostics.js",
	"clip-web-receiver.js":    "assets/clip-web-receiver.js",
	"clip-viewer-state.js":    "assets/clip-viewer-state.js",
}

// viewerPage serves one byte-identical, trusted application shell for every
// presentation-only room code. The short code and the secret URL fragment are
// interpreted entirely by the browser; neither is injected into server HTML.
func (s *Service) viewerPage(writer http.ResponseWriter, request *http.Request) {
	roomCode := request.PathValue("room")
	if !validViewerRoomCode(roomCode) || request.URL.RawQuery != "" ||
		request.URL.EscapedPath() != "/"+roomCode {
		http.NotFound(writer, request)
		return
	}
	data, err := fs.ReadFile(viewerweb.Assets, viewerPagePath)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "viewer_unavailable")
		return
	}
	setViewerSecurityHeaders(writer, request)
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
	writer.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(data)
}

func (s *Service) viewerAsset(writer http.ResponseWriter, request *http.Request) {
	asset := request.PathValue("asset")
	embeddedPath, allowed := viewerAssets[asset]
	if !allowed || request.URL.EscapedPath() != "/assets/"+asset {
		http.NotFound(writer, request)
		return
	}
	data, err := fs.ReadFile(viewerweb.Assets, embeddedPath)
	if err != nil {
		http.NotFound(writer, request)
		return
	}
	setViewerSecurityHeaders(writer, request)
	writer.Header().Set("Content-Type", viewerAssetContentType(asset))
	// Asset names are stable across server releases, so revalidate a strong
	// content hash instead of caching an old viewer forever. The files remain
	// immutable for the lifetime of the embedded server binary.
	writer.Header().Set("Cache-Control", "public, max-age=0, must-revalidate")
	writer.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
	digest := sha256.Sum256(data)
	etag := `"` + hex.EncodeToString(digest[:]) + `"`
	writer.Header().Set("ETag", etag)
	if request.Header.Get("If-None-Match") == etag {
		writer.WriteHeader(http.StatusNotModified)
		return
	}
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(data)
}

func viewerAssetContentType(asset string) string {
	if strings.HasSuffix(asset, ".css") {
		return "text/css; charset=utf-8"
	}
	return "text/javascript; charset=utf-8"
}

func validViewerRoomCode(value string) bool {
	if len(value) != viewerRoomCodeLength {
		return false
	}
	for index := range len(value) {
		character := value[index]
		if (character < 'A' || character > 'Z') &&
			(character < '0' || character > '9') {
			return false
		}
	}
	return true
}

func setViewerSecurityHeaders(
	writer http.ResponseWriter,
	request *http.Request,
) {
	// The page is a receive-only, dependency-free client. WebSocket access is
	// limited to the exact request host; no third-party scripts, styles, media,
	// frames, forms, workers, or plugins can be introduced by the document.
	webSocketSources := ""
	if validCSPHost(request.Host) {
		webSocketSources = " ws://" + request.Host + " wss://" + request.Host
	}
	writer.Header().Set(
		"Content-Security-Policy",
		"default-src 'none'; "+
			"base-uri 'none'; form-action 'none'; frame-ancestors 'none'; "+
			"object-src 'none'; worker-src 'none'; "+
			"script-src 'self'; style-src 'self'; "+
			"connect-src 'self'"+webSocketSources+
			" stun: stuns: turn: turns:; "+
			"img-src 'self' data:; media-src 'self' blob:",
	)
}

func validCSPHost(value string) bool {
	if value == "" || strings.ContainsAny(value, " \t\r\n/\\;'\"") {
		return false
	}
	for _, character := range value {
		if (character < 'A' || character > 'Z') &&
			(character < 'a' || character > 'z') &&
			(character < '0' || character > '9') &&
			!strings.ContainsRune(".-:[]", character) {
			return false
		}
	}
	return true
}

// ServeMux canonicalizes dot segments before route selection. Intercept only
// the viewer asset namespace first so traversal attempts receive 404 instead
// of a redirect that could alias an unrelated endpoint.
func rejectViewerPathAliases(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if strings.HasPrefix(request.URL.Path, "/assets") {
			escaped := request.URL.EscapedPath()
			if escaped != request.URL.Path ||
				path.Clean(request.URL.Path) != request.URL.Path ||
				strings.Contains(request.URL.Path, "\\") {
				http.NotFound(writer, request)
				return
			}
		}
		next.ServeHTTP(writer, request)
	})
}
