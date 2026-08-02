# Receive-Only Web Participant Mesh

Status: implementation contract for web-v1.

The Clip web viewer is a first-class, receive-only participant in the existing
encrypted server-room-v4 mesh. It is not a second signaling system, a media
mirror, a host-served stream, or a special native peer-link type.

## One mesh contract

For native participants A and B and web participant W, the topology is:

```text
A <-> B
A <-> W
B <-> W
```

Every edge uses the same authoritative v4 roster, stable pair identity,
deterministic offerer rule, pairwise encrypted SDP/ICE messages, fixed media
slots, and reliable ordered control DataChannel. The native participant does
not choose a different transport because the remote client is a browser. A
browser implements the same pair contract with the platform
`RTCPeerConnection` API.

The encrypted, creator-certified member descriptor carries a closed,
versioned profile:

- `nativeApp / nativeV1`
- `webViewer / webViewerV1`

This profile controls product capabilities and presentation only. It is not
visible to the rendezvous service and cannot change routing.

## Web-v1 capabilities

The web viewer:

- joins by the canonical reusable v4 invite;
- counts toward the existing four-participant room limit;
- owns one direct pair with every other room member, including another web
  viewer;
- receives up to four video sources and one system-audio track from every
  native participant;
- receives source/focus/cursor metadata needed to present those sources;
- appears in Native and Web participant lists with a Web badge;
- may leave and reconnect its own tab session;
- publishes an authenticated empty source snapshot and no media tracks.

The web viewer cannot:

- create or administer a room, rotate invites, approve or remove people;
- publish a window, fullscreen video, microphone, or system audio;
- create or accept friendships;
- send or render collaboration pointers, pings, or ink;
- control another participant's native viewer windows.

The absence of these features is enforced by the authenticated profile and
hidden UI. It is not inferred from a user-agent string.

That profile is an authenticated, creator-certified participant declaration,
not platform attestation. It prevents an admitted participant declared as Web
from using Web-forbidden protocol features, but a custom malicious client could
declare `nativeApp/nativeV1` unless a future release adds Native application
attestation. Admission policy and the four-person room boundary therefore
remain part of the trust model.

## Exact codec rule

Each publishing participant's selected video codec is the only codec offered
for that participant's video transceivers. Clip never performs a second encode
for a browser and never silently falls back to VP9, VP8, or H.264.

If the browser cannot decode the selected codec:

- authoritative roster presence remains live;
- the affected source shows `Unsupported Encoding: <codec>` when the selected
  codec is observable before the incompatible peer connection fails;
- otherwise that peer's video may remain unavailable or black;
- fallback negotiation, transcoding, and duplicate encoders are never allowed.

Current libwebrtc rejects an exact-codec SDP as a whole when the endpoints have
no common video codec; it does not reliably reject only the video m-lines.
Web-v1 therefore does not promise audio or a DataChannel on that incompatible
edge, nor does it promise that every browser can name a codec it never
successfully negotiated. It reports the codec incompatibility when that
information is available while every unrelated mesh edge continues unchanged.
Adding a separate codec preflight or split media/control transport would alter
the proven native mesh and is deliberately outside this pass.

Native-to-native behavior uses this same exact-codec rule.

## Invite and privacy

Native and Web use the same invitation:

```text
https://service.example/ROOMCODE#v=4&key=<sealed-payload>&join=<capability>
```

The fragment is decrypted only by the repository-owned web client. With the
unmodified Clip server binary and viewer assets, it is never sent in an HTTP
path, query, cookie, request header, WebSocket outer message, analytics event,
or service log. The browser page and every asset are self-hosted by the room
service; there are no third-party scripts, fonts, styles, analytics, or CDNs.

The web origin is nevertheless part of the trusted client-distribution
boundary. JavaScript served by that origin can read the fragment; a malicious
or compromised room-service deployment could therefore replace the viewer and
exfiltrate it. Clip does not claim fragment secrecy from a malicious serving
origin. Internet viewer links require HTTPS. Plain HTTP is accepted only for
the exact loopback hosts `localhost`, `127.0.0.1`, and `[::1]` during local
development.

An honest deployment cannot inspect the encrypted declared participant
profile, identities, names, SDP, ICE, sources, codecs, or media. Serving the
viewer page, browser reconnect endpoint, and WebSocket subprotocol can reveal
that a client is using the Web surface; normal requests do not reveal the
fragment secret or encrypted profile. The service otherwise sees only the
existing bounded room routing metadata and ciphertext traffic.

## Browser session and reconnect

One browser tab owns one ephemeral participant identity. Refresh in the same
tab restores that identity and reconnect capability from tab-scoped browser
storage. Explicit Leave deletes it. Opening the invite in another tab creates
a distinct candidate and room member.

Browsers cannot set arbitrary WebSocket authorization headers. A same-origin
POST exchanges a reconnect capability from an `Authorization` header for one
short-lived, single-use opaque ticket. The browser presents that ticket in the
WebSocket subprotocol header, never in a URL, query, or cookie. The room hub
still performs the authoritative reconnect-capability check while attaching
the socket; the native authorization path is unchanged.

## Media presentation

All active sources remain selectable. The initial web UI supports Focus, Grid,
and Row layouts plus Fit, Fill, Native size, cursor-follow panning, and browser
fullscreen.

Follow targets a participant rather than a transient window:

1. With no active publisher, show a waiting state.
2. With one active publisher, follow them automatically.
3. With several active publishers, retain the current target and show a
   participant selector.
4. Within the target participant, follow their focused source, otherwise their
   first active source in stable source order.
5. If that source stops, select the next source from the same participant.
6. If that participant stops or leaves, select the next active publisher in
   authoritative roster order.
7. Do not jump back if an earlier publisher resumes later.
8. Clicking another participant's source changes the Follow target to that
   participant.

System audio remains one track per publishing participant. The browser starts
muted until an explicit user gesture unlocks playback, then provides a master
mute/volume plus per-participant mute/volume.

## Compatibility boundary

Web-v1 targets current desktop Safari and Chromium. Firefox and mobile
browsers are not release claims. Browser capability probing may report an
unsupported selected codec; it may not select a different codec.

The following native implementation is frozen by this feature:

- ScreenCaptureKit source selection and frame handling;
- source-aware `.nominal` 1x and `.best` Retina capture policy;
- window/display geometry, cursor capture, masking, and collaboration overlay;
- capture frame rate, bitrate, color, encoder, quality, and system-audio
  publishing;
- retained native-to-native pair identity and continuity.

## Release gates

- Swift and JavaScript share canonical fixtures for invite, member descriptor,
  admission, roster, pair encryption/signaling, and source snapshots.
- A + B + Web produces exactly three ready links; adding/removing Web leaves
  A-B's transport ID, negotiation epoch, tracks, codec, and media uninterrupted.
- A + B + C + Web produces exactly six ready links.
- Unsupported selected codec proves one encoder, no fallback, a codec-specific
  browser error when the codec is observable, and no disturbance to another
  pair. A peer connection that fails before exposing the codec may remain
  unavailable or black.
- All existing native 2-, 3-, and 4-participant acceptance remains green.
- A repository diff gate rejects changes to frozen native capture/media paths.
