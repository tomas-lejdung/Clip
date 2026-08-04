# Clip

Clip is a native macOS menu-bar app for recording and sharing clear screen
clips with very little setup.

Choose an area, application, or display; record; trim; then drag or copy the
MP4 into the place where you need it. Recordings stay on your Mac unless you
explicitly start Live Share.

## What Clip does

- Records an area, an application, one display, or fullscreen.
- Captures the cursor, optional click highlights, microphone, and system audio.
- Pauses and resumes without leaving a timing gap in the result.
- Opens a Preview for playback, trimming, renaming, and removing audio.
- Exports native-resolution Crisp, Compact, or Smallest MP4 files.
- Shares through drag, Copy, or Save As.
- Keeps a local, automatically cleaned recording history.
- Runs from the menu bar and can hide its Dock icon.
- Supports optional, encrypted Live Share sessions.

The complete product behavior is documented in [spec.md](spec.md).

## Local by default

Recording, Preview, History, trimming, and export work without an account,
server, or network connection. Clip has no cloud-upload service, analytics, or
AI processing. The files it manages live in the app's local Application
Support and Caches containers; files created with Save As belong to you and are
never removed by Clip.

Screen Recording permission is required to capture the screen. Microphone and
system-audio permissions are requested only if you enable those features. Clip
does not request Accessibility permission.

## Live Share

Live Share is optional. It lets Native Clip participants publish windows or a
fullscreen display while receiving the other Native participants' sources. A
desktop Safari or Chromium browser can join the same room as a receive-only
viewer.

A room supports up to four participants in a complete peer-to-peer WebRTC
mesh. Two people sharing together is the primary use case. Four is the current
tested resource boundary, not a fundamental WebRTC limit: every additional
peer adds another direct connection, encoder/RTP sender per published source,
decoder, and copy of the outgoing network traffic.

For three participants A, B, and C, the direct links are A-B, A-C, and B-C.
The service does not forward media between them. TURN may relay a connection
when a direct route is unavailable, but the relayed WebRTC traffic remains
encrypted.

### What the room service can see

The room service maintains a bounded opaque roster and routes encrypted
admission and pair-signaling envelopes. With the official Native clients, it
does not receive participant names or identities, invite-fragment secrets,
plaintext SDP/ICE, source titles, collaboration events, or media. It can see
ordinary operational metadata such as IP addresses, timing, room size, opaque
routing identifiers, and ciphertext sizes, and it can always deny service.

Invite secrets live in the URL fragment and are not included in normal HTTP or
WebSocket requests. Pair signaling and control messages are authenticated and
end-to-end encrypted. Media uses WebRTC's encrypted transports.

There is one important Web caveat: the room-service origin supplies the Web
viewer JavaScript. A malicious or compromised origin could serve modified code
that reads the invite fragment. Native-to-Native sharing has the stronger
separation because the server does not supply either Native client. You can
self-host the service and Web viewer if you want to control that origin.

The creator controls admission and ends the room for everyone. An ordinary
participant can leave independently. There is deliberately no creator
election: creator departure ends the room instead of entering an ambiguous
locked state.

See [the mesh design](docs/server-coordinated-mesh-design.md), [Web viewer
design](docs/web-viewer-mesh-design.md), and [server documentation](server/README.md)
for protocol, deployment, and security details.

## Install

Clip targets Apple Silicon and macOS 15 or later.

1. Download `Clip.dmg` from [GitHub Releases](https://github.com/tomas-lejdung/Clip/releases).
2. Drag Clip into Applications.
3. Open Clip from Applications; it appears in the menu bar.
4. Start a capture and approve **Screen & System Audio Recording** when macOS
   asks.

Local Personal Team builds are Apple Development signed. Public builds are not
currently Developer ID notarized, so macOS may require **Open Anyway** after a
download.

## Build from source

Requirements:

- Xcode 26.6 with Swift 6.3.3
- Apple Silicon Mac running macOS 15 or later
- Go 1.25 when developing or self-hosting the Live Share service

```bash
# Strict Swift/package verification
./scripts/typecheck.sh

# Package and app tests
./scripts/test.sh

# Build the macOS app
./scripts/build.sh Debug

# Build and verify a local DMG
./scripts/package-dmg.sh
./scripts/verify-dmg.sh .build/Clip.dmg
```

The complete Live Share acceptance lane is:

```bash
./scripts/run-live-share-acceptance.sh
```

Some real ScreenCaptureKit and UI tests need existing macOS privacy grants and
explicitly move the visible pointer. They are never started by the ordinary
test command. See [ACCEPTANCE.md](docs/ACCEPTANCE.md) before running them.

## Self-host Live Share

The Go room service and embedded receive-only Web viewer live in [`server/`](server).
For local development:

```bash
cd server
go run ./cmd/clip-live-share-server
```

The default address is `http://localhost:8080`. Internet deployments require
HTTPS/WSS through a TLS reverse proxy. The service stores room state in memory;
restarting it ends active room membership. Docker configuration, limits,
origin policy, STUN/TURN settings, and publication commands are in
[server/README.md](server/README.md).

You can also ignore Live Share entirely: no server is involved in Clip's normal
recording workflow.

## Documentation

- [Product specification](spec.md)
- [Technical architecture](ARCHITECTURE.md)
- [Acceptance and evidence boundaries](docs/ACCEPTANCE.md)
- [Current implementation status](PROGRESS.md)
- [Live Share mesh design](docs/server-coordinated-mesh-design.md)
- [Receive-only Web viewer design](docs/web-viewer-mesh-design.md)
- [Performance methodology](docs/PERFORMANCE.md)
- [Release process](docs/RELEASING.md)
- [Third-party notices](Clip/Resources/ThirdPartyNotices.txt)

## License and distribution

Clip is a personally maintained direct-download application. It is not an App
Store release. Copyright © 2026 Tomas Lejdung.
