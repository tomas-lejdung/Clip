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

## Codec boundary

On every Native-Web edge, the publishing participant's selected video codec is
the only codec offered for its video transceivers. Clip never performs a second
encode for a browser and never silently falls back to VP9, VP8, or H.264.

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

Native-to-native edges deliberately retain the proven pre-Web SDP preference
ladder:

- AV1 prefers AV1, then VP9, then VP8;
- VP9 prefers VP9, then VP8;
- H.264 offers H.264 only;
- VP8 offers VP8 only.

This is a compatibility preference during negotiation, not multi-codec
publishing. A Native publication still uses one negotiated codec and one
encoder; Clip does not generate simultaneous per-peer encodings. Adding a Web
participant must not replace or renegotiate an unaffected Native-Native edge.

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

When a restored browser is the canonical answerer, its replacement
`RTCPeerConnection` requests an authenticated ICE restart from the permanent
offerer. Ordinary renegotiation is insufficient because it can reuse the
offerer's prior ICE credentials. This restart is pair-local and does not
recreate or renegotiate any unaffected room edge.

Browsers cannot set arbitrary WebSocket authorization headers. A same-origin
POST exchanges a reconnect capability from an `Authorization` header for one
short-lived, single-use opaque ticket. The browser presents that ticket in the
WebSocket subprotocol header, never in a URL, query, or cookie. The room hub
still performs the authoritative reconnect-capability check while attaching
the socket; the native authorization path is unchanged.

## Media presentation

All active sources remain selectable. Web-v1 supports Focus and Row layouts;
Grid is intentionally removed. Native size is the default, with Fit, Fill,
browser fullscreen, drag-to-pan when a Native source exceeds the viewport, and
a bottom-right minimap showing the visible region.

The Focus HUD auto-hides after pointer/input inactivity and reappears on
movement. Its filmstrip shows every active source. Green identifies the source
focused by its publisher; blue identifies a source selected manually by this
viewer.

Follow targets a participant rather than a transient window and includes an
explicit Off state:

1. With Follow Off, keep the viewer's manually selected source.
2. With Follow enabled, retain the selected publisher and expose a publisher
   selector whenever more than one participant is sharing.
3. Within that publisher, follow their focused source, otherwise their first
   active source in stable source order.
4. If that source stops, select the next source from the same participant.
5. If that participant stops or leaves, select the next active publisher in
   authoritative roster order.
6. Do not jump back if an earlier publisher resumes later.
7. Clicking a source in the filmstrip selects it manually and turns Follow Off.

System audio remains one track per publishing participant. The browser starts
muted until an explicit user gesture unlocks playback, then provides a master
mute/volume plus per-participant mute/volume.

Video receivers request the live edge (`jitterBufferTarget = 0` and
`playoutDelayHint = 0` where the browser exposes those optional hints), matching
the original Web viewer's low-latency behavior. Audio retains a small jitter
reservoir to avoid scheduler and network dropouts. Unsupported or read-only
browser hints never fail an otherwise healthy peer link.

The viewer's read-only Diagnostics page reports each direct connection's
P2P/TURN route, RTT, ICE/control state, negotiated codec, decoded dimensions,
FPS, measured receive rate, and packet loss. Missing browser statistics are
reported as unavailable. Its copied report includes the room code but never
the invite fragment or cryptographic capability.

Explicit Leave is terminal for that tab session. Media controls, participant
actions, and the Leave button are removed and replaced with a Join Again
action. The terminal message also makes clear that the user may close the tab;
the page does not expose a nonfunctional `window.close()` control that browsers
normally reject for user-opened tabs.

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
- Unsupported selected codec on a Native-Web edge proves one encoder, no
  fallback, a codec-specific browser error when the codec is observable, and
  no disturbance to another pair. A peer connection that fails before exposing
  the codec may remain unavailable or black.
- Native-Native negotiation retains the AV1→VP9→VP8 and VP9→VP8 preference
  ladders (with H.264 and VP8 exact) while using one active codec and one
  encoder.
- Controlled desktop Safari and Chromium acceptance covers Native-default
  rendering, Focus/Row, Follow Off and per-publisher Follow, filmstrip source
  selection, HUD auto-hide, Native drag/minimap, fullscreen, and audio. This
  remains a manual release gate until it has been run on both browsers.
- All existing native 2-, 3-, and 4-participant acceptance remains green.
- A repository diff gate rejects changes to frozen native capture/media paths.
