Here is the finalized product specification for **Clip**.

# Clip — Product Specification

## Product summary

**Clip** is a lightweight native macOS screen recorder for creating short, compact product and development demos.

Its primary workflow is:

1. Choose an area of the screen, an application, or a display.
2. Record a short demonstration.
3. Trim the beginning or end.
4. Drag the video from the preview, or copy a compact MP4.
5. Drop or paste it directly into Slack, GitHub, Linear, Discord, or another application.

Clip is not intended to replace a full video editor or general screenshot suite. It should do one task extremely well:

> Record and share a clear screen clip with as little friction as possible.

---

## Product principles

Clip should be:

- Fast to activate.
- Native to macOS.
- Primarily controlled from the menu bar.
- Optimized for short recordings.
- Designed around sharing rather than video production.
- Simple enough that users rarely need to open a settings window.
- Local-first recording with no account or upload service; Live Share is a
  separate explicit mode that requires the configured room coordination
  service.
- Able to produce compact files while preserving readable interface text.

---

# Core user experience

## Application behavior

Clip launches as a menu-bar application.

By default:

- No regular application window opens.
- No Dock icon is shown.
- A Clip icon appears in the macOS menu bar.
- Launch at login is Off but may be enabled in Settings.
- Clip follows the current macOS light or dark appearance.
- Clip is English-first and uses a String Catalog so later localization remains straightforward.

Clicking the menu-bar icon opens the main Clip popover.

Clip also provides an optional **Live Share** workflow. Up to four Native Clip
and receive-only Web participants can join one room. Native participants may
share their own macOS windows or one entire display and receive every other
Native participant's sources; Web participants receive compatible Native
sources but never publish. Every admitted pair uses a direct encrypted WebRTC
connection. Clip's in-repository Go service owns the authoritative bounded
opaque roster, socket presence, reconnect grace, and encrypted pair-signal
routing. It never receives media, plaintext Access Words, participant names or
identities, trust decisions, plaintext SDP/ICE, source metadata, or
collaboration content.

---

## Menu-bar popover

The default popover contains:

```text
Capture Area…
Capture App…
Last Area
Fullscreen
Display 1
Display 2

Microphone        Off
System Audio      Off
Click Highlights  Off

● Record

Recent Recordings
Settings
Quit Clip
```

The idle popover includes **Create Room** and **Join Invite**. Once a v4
room session exists, the entire popover switches to the common participant room
surface rather than mixing recording and sharing actions in one menu.

---

# Live Share

## Server-coordinated v4 room model

Live Share is a clean-slate Clip participant mesh. **Create Room** and
**Join Invite** both start the same participant session directly. Native apps
and receive-only web viewers use the same authoritative roster, admission,
pair identity, encrypted signaling, and direct WebRTC connection machinery.
The signed member profile changes product capabilities and presentation only;
it never selects a different native transport or routing path. There is no
permanent native host/viewer media role, legacy protocol negotiation, in-place
upgrade, role handoff, media mirror, or compatibility path.

The room creator owns admission and room-level controls. The service owns only
the authoritative opaque roster and encrypted pair-signal routing; neither the
creator nor the service relays another participant's media or owns another
participant's source state. Every admitted native participant can concurrently:

- Publish up to four exact windows or one mutually exclusive fullscreen
  display.
- Publish one optional system-audio track.
- Receive every other native participant's video, system audio, focus context,
  collaboration events, and directional diagnostics.
- Independently add, update, stop, hide, reopen, resize, or fullscreen its
  local and remote presentations without ending the room.

The product limit is four participants, including the creator and every web
viewer. A complete room therefore contains six direct peer links. Raising the
participant limit requires a new CPU, thermal, upstream-bandwidth, churn,
audio-mixing, and real-network acceptance pass.

Recording and Live Share remain mutually exclusive. Joining or creating a room
first completes deterministic teardown of any current recording or room
session. Late callbacks from a superseded session are ignored.

## Invite and admission

Creating a room reserves a fresh opaque service-room identifier, creates a
client-only room agreement secret and stable admission capability, and produces
one self-contained invite for both Clip and its web viewer:

```text
https://service.example/ROOMCODE#v=4&key=<sealed-client-payload>&join=<admission-capability>
```

`ROOMCODE` is an eight-character presentation code. It is not the service API
room ID and grants no access. The encrypted `key` payload contains the opaque
256-bit API room ID, session binding, creator identity, room agreement secret,
and a copy of the admission capability. `join` derives the payload-encryption
key and authorizes a candidate to knock. The unmodified client never places
either fragment value in an HTTP path, query, header, server log, or outer
WebSocket message. The client decrypts the API room ID before contacting the
service; that opaque ID is routing material and never authorizes membership by
itself. AES-GCM authenticated data binds the sealed payload to the exact
`/ROOMCODE` path.

The room popover provides:

- The room name and one clear **Copy Invite** action.
- **New Invite**, which invalidates the prior invitation route and publishes
  fresh join material without disrupting admitted participants.
- An optional generated **Access Word** that can be enabled, copied, replaced,
  or disabled for future admissions.
- An optional **Ask Before Joining** setting. It is off by default.
- When approval is required, prominent pending admission cards with explicit
  **Allow** and **Deny** actions.

The join capability is the mandatory anonymous admission secret. The optional
Access Word is an independent short confirmation shared separately. The
candidate proves both inside an encrypted server-room-v4 knock, bound to the
exact room, session, participant identity, and creator. The room service never
receives either secret or a plaintext proof.
Replacing or disabling the Access Word affects future candidates only and does
not eject admitted participants.

Every native Clip installation owns a persistent P-256 signing identity stored
as device-only Keychain material; the receive-only web identity is scoped to
one browser tab as described below. A room name, rendezvous identifier,
identity, or Access Word alone never grants membership. By default, successful
proof of the full high-entropy invite capability auto-admits a candidate after
identity, capability, optional Access Word, duplicate, capacity, and room-availability
validation. **Ask Before Joining** adds a creator-controlled approval boundary
after those checks. The signed room descriptor tells an authenticated
candidate whether approval is required; while waiting, Clip identifies the
room and current admission authority without exposing room contents. Approval
or automatic admission installs one creator-signed encrypted member descriptor
in the service roster. Denial, timeout, invalid proof, or room-capacity failure
removes all candidate resources.

## Membership and room lifetime

The service publishes one complete authoritative opaque roster after every
membership change. Every member decrypts and verifies each creator-signed
descriptor, room/session binding, revision, creator continuity, and identity
uniqueness before reconciling its peer links. Participant IDs are random per
room and source identity is the tuple of publisher participant ID and
source-instance ID.

For every unordered participant pair there is exactly one independent direct
WebRTC connection. For A, B, and C the topology is A-B, A-C, and B-C. Applying
a new roster is set reconciliation: retained pairs are never replaced merely
because another participant joined, left, or reconnected. A pair failure is
isolated to that pair and cannot roll back any other connection.

When an ordinary participant rejoins, its fresh member incarnation replaces
only its stale pair/source state. Every ready pair exchanges the publisher's
current authoritative source manifest, so all active windows reappear without
requiring the publisher to stop and reshare them.

An ordinary participant may leave without ending the room; the service removes
only that participant and broadcasts the next complete roster. The creator has
one terminal **End Room for Everyone** action. If the creator explicitly leaves
or its signaling reconnect grace expires, the service ends the room for every
participant. There is no election, successor, authority chain, quorum, or
`leaderlessLocked` phase.

The invite URL remains byte-for-byte stable across joins, leaves, reconnects,
descriptor refreshes, and roster revisions. Only the explicit **New Invite**
action rotates the admission capability and changes the copied URL; it does not
replace the room ID or interrupt admitted participants.

## Receive-only web participants

The same-origin web viewer is a first-class member of the server-room-v4 mesh,
not a mirrored stream or separate signaling product. For native participants A
and B and web participant W, the direct topology is A-B, A-W, and B-W. Web-Web
pairs retain the same authenticated DataChannel contract even though neither
side publishes media.

The room-service origin is part of the trusted Web client distribution. A
malicious or compromised origin can serve modified JavaScript that reads and
exfiltrates the fragment, so the product does not claim fragment secrecy from
that origin. Internet viewer links require HTTPS; plain HTTP is accepted only
for exact `localhost`, `127.0.0.1`, and `[::1]` development links.

The encrypted creator-certified member descriptor contains one required,
closed profile: `nativeApp/nativeV1` or `webViewer/webViewerV1`. Native clients
run the normal pair reconciliation and concrete peer-link code for either
profile. The profile only allows the UI and protocol boundary to enforce that a
web viewer:

- receives up to four video sources and one system-audio track from every
  native publisher;
- receives authenticated source, focus, and cursor metadata needed to present
  those sources;
- appears in participant and connection lists with a **Web** badge;
- publishes an authenticated empty source snapshot and no media;
- may leave and reconnect its own tab session;
- cannot create or administer a room, rotate invitations, approve or remove
  members, publish media, create friendships, send or render collaboration, or
  control native viewer windows.

The profile is an authenticated, creator-certified participant declaration;
it is not platform attestation. A custom malicious client could claim
`nativeApp/nativeV1` unless a future release adds Native application
attestation. The Web capability gate prevents a participant declared as Web
from publishing or using forbidden controls, while creator admission and the
four-person room limit remain part of the trust boundary.

One tab owns one ephemeral participant identity. Refresh in that tab restores
its identity and reconnect capability from tab-scoped storage; explicit Leave
deletes it, and opening the invite in another tab creates another participant.
Because browsers cannot set a WebSocket authorization header, a same-origin
POST exchanges the reconnect capability for a short-lived, single-use opaque
ticket presented in the WebSocket subprotocol. The capability and ticket never
appear in a URL, query, cookie, or service log, and the existing room hub still
makes the authoritative reconnect decision.

The browser presents all active sources using Focus or Row layout; Grid is not
part of web-v1. Native size is the default, with Fit, Fill, drag-to-pan for an
oversized Native source, a bottom-right viewport minimap, and browser
fullscreen. The Focus HUD auto-hides after pointer/input inactivity, returns on
movement, and shows a filmstrip of every active source. The filmstrip
distinguishes the publisher-focused source from the viewer's manually selected
source.

Follow is participant-scoped and explicitly supports **Off**. With Follow Off,
the viewer selects and keeps any source manually. With Follow enabled, the
viewer selects a publisher and tracks that publisher's focused source; if that
source stops, Clip advances within the publisher, and if the publisher stops
or leaves, Clip advances to the next active publisher in authoritative roster
order. Manually selecting a source turns Follow Off. System audio is one track
per native publisher, initially muted until a user gesture, with master and
per-participant mute/volume.

Web-v1 targets current desktop Safari and Chromium. Firefox and mobile browsers
are not release claims. Web participants have no friendship or collaboration
surface in this version.

## Friends

A native participant may send **Add Friend** from another Native participant's
room row.
Friendship is established only after a signed request, explicit remote
acceptance, requester acknowledgement, and accepter commit receipt cross that
pair's already-authenticated reliable DataChannel. Both devices durably commit
the same persistent P-256 identity or neither presents the relationship as
trusted. Requests and receipts are idempotent and crash recoverable.

Every friendship owns two independent opaque presence mailboxes: one for each
direction. Each mailbox contains a random routing ID and random symmetric read
secret exchanged only over the authenticated pair. A participant with an
active room publishes a short-lived, signed, AES-GCM-encrypted copy of the
current canonical v4 invite separately for each friend. The service stores only
the opaque routing ID, monotonic revision, expiry, and bounded ciphertext. It
never receives the friend graph, identity, name, trust decision, room code, API
room ID, invite fragment, or presence key.

The idle Live Share pane lists saved friends that are currently sharing.
Selecting a friend decrypts and verifies their presence, pins the expected
identity, and joins through the normal v4 room path. A saved-friend join always
appears to that friend as a prominent **Allow** or **Deny** request even when
the room's general **Ask Before Joining** setting is off. The candidate sees a
clear waiting state. Removing a friend deletes both local mailbox secrets and
stops future discovery; it does not remove an already admitted room member.

## Common native participant popover

Every native participant sees the same fluid, content-sized room popover.
Creator authority changes available room actions, not the media layout. The
popover uses shared pane, section, row, toggle, picker, metric, and action-button
components so the creator and later joiners remain visually identical.

The native creator sees Copy/New Invite, Access Word, Ask Before Joining,
pending approval, member removal, and End Room authority. Other native
participants see the same room identity and participant state without disabled
creator-only placeholders. A pending request raises the menu-bar attention
state and appears as a top-level Allow/Deny card; it is never hidden inside room
settings.

Participant rows identify the authenticated profile as **Native** or **Web**.
Friendship controls are available only for Native profiles. The web viewer uses
its dedicated receive-only layout rather than exposing disabled native
publishing or room-administration controls.

The overview contains:

- Room name and invite state.
- **Your Share**, with the participant's local sources, add/share controls,
  system-audio publication, app-audio exclusions, and local stream state.
- A compact **Shared With You** navigation row summarizing `N windows from M
  people`. Its fluid detail pane groups visible and hidden windows, audio
  playback, volume, connection route, and bring-to-front controls by remote
  participant. **Your Share** remains expanded on the overview.
- Room participants and pending admission state.
- Stream Settings and Statistics.
- Pointer, ping, and drawing controls.
- **Bring All to Front**, plus per-source show/bring-forward controls.
- **Leave Room** for an ordinary participant, and **End Room for Everyone** for
  the creator.

Starting or remaining connected with zero local sources is valid. Each remote
participant section shows an explicit waiting state until that participant
publishes a source. New remote source windows come forward once without
becoming permanently floating, and hidden windows remain reopenable.

## Local sources and audio

Clip shares exact windows rather than every window owned by an application.
Each native participant may share up to four exact windows concurrently. Each source
keeps its stable reserved WebRTC track slot for the lifetime of the room so
adding or removing a source does not require a new peer connection.

A source-scoped capture failure is a transient notice, not persistent room
state. Clip clears it only after authoritative publication/capture state proves
that source recovered, or after the failed source or participant incarnation is
removed. A recovered source must not leave a stale `Capture is not running`
banner over otherwise working sharing controls.

Fullscreen is locally exclusive:

- Enabling fullscreen stops that participant's exact-window capture sessions
  and publishes one display source.
- Adding an exact window turns that participant's fullscreen source off first.
- Stopping fullscreen leaves the participant connected and ready to publish a
  different source.

An optional Auto Share setting follows eligible focused windows. It obeys the
same four-source limit and uses deterministic least-recently-focused
replacement when the pool is full. Manual source management remains the
default.

Each native participant may optionally publish system audio. The state defaults
to Off and persists independently from recording audio. Exact-window sharing
captures audio for the unique owning applications of that participant's shared
windows; macOS filters audio at application scope, not individual-window scope.
Fullscreen captures system audio while always excluding Clip and may also
exclude one or more user-selected applications, such as Discord. The exclusion
row shows `None`, the selected application name, or `N Apps`.

Multiple windows from one application never produce duplicate audio tracks.
ScreenCaptureKit feeds one stable 48 kHz stereo Opus track from each publishing
participant. Live Share does not send microphone audio. Every receiver plays
each remote participant's audio exactly once and owns an independent mute and
volume control for that participant.

## Remote source windows

Each received source uses one independent native macOS window:

- It uses the publisher's authoritative logical dimensions independently of
  the receiver display's backing scale.
- **Follow** uses native rendering and continually matches the publisher's
  logical window size. Manually resizing a Follow window changes it to
  **Native**.
- **Native** keeps the source at its logical native size inside a
  receiver-controlled viewport. A smaller viewport crops and pans toward the
  remote cursor; a larger viewport does not blur or invent source detail.
- **Fit** preserves the complete source aspect ratio inside a
  receiver-controlled window.
- Local fullscreen aspect-fits the source with auto-hiding controls and restores
  the prior frame and presentation mode when it exits.
- Windows can be moved, resized, minimized, placed in another Space or display,
  hidden/reopened, brought forward individually, or brought forward together
  without affecting the publisher.
- The window is borderless with a participant-identity-colored frame and
  matching external drag header. Remote focus changes its treatment without
  raising, moving, or stealing local focus.

The receiver owns placement. Publisher movement does not overwrite a manually
arranged receiver window. Removing a source closes its presentation. Closing
the last visible source while remote audio remains active asks whether to stay
connected or leave.

Source-aware ScreenCaptureKit resolution is mandatory. A genuine 1× source
uses nominal capture resolution and a Retina source uses best capture
resolution so mixed-display topology never causes a destructive resample.
Source geometry, scale metadata, and native cursor behavior are re-evaluated
when a shared window moves between displays.

The server-room-v4 mesh replaces only room signaling, membership, and peer
coordination. It must reuse the established capture and media contract without
changing its algorithms: source-aware 1×/Retina resolution, geometry and pixel
formats, cursor/focus behavior, codec-specific H.264 constraints, codec
transition ordering and rollback, quality allocation, encoder settings,
system-audio sequencing, and captured-frame delivery remain behaviorally
identical to the pre-mesh Live Share pipeline.

## Sharing controls, focus, and cursor

The local participant's currently focused eligible window gets a small
capture-excluded overlay with **Share** or **Stop**. An arrow moves it between
the left and right edge. A capture-excluded status overlay shows one dot per
local exact-window source, room participant count, and a fullscreen toggle.
Clip-owned, hidden, desktop, protected, and otherwise unshareable windows never
receive the control.

Both overlays use AppKit discovery and ordinary button input without an
Accessibility event tap, pointer takeover, or remote input injection.

Clip publishes source focus and native cursor context for the local
participant's focused source. Remote presentations reject stale, wrong-source,
wrong-participant, and superseded-session cursor events. Publisher focus may
change a remote frame treatment and cursor route, but never moves or focuses a
receiver's local windows.

## Collaboration

Every native participant may deliberately reveal a collaboration pointer over a
remote source, create a bounded ping, or draw temporary vector ink. These
events use the existing pairwise WebRTC DataChannels rather than a media
encode or server route. Replaceable pointer motion is coalesced to a latest-
wins 60 Hz ceiling and may be dropped under transport pressure; pings, ink,
and clear commands use reliable ordered delivery. Pointer movement refreshes a
two-second activity lease; the sender emits one hidden sample when movement
stops, and receivers independently expire stale pointers after the same two
seconds in case that ephemeral hide packet is lost.

- Pointer and ping events contain origin participant, source key, normalized
  source coordinates, positive sequence, timestamp, visibility, and bounded
  lifetime.
- Drawing uses bounded begin/points/end events with a stable stroke ID, origin
  participant, source key, color, and expiry.
- Pointer and ink are rendered as resolution-independent local overlays at the
  publisher and receivers. They are excluded from source capture to prevent a
  feedback loop and never reduce the encoded source quality.
- A publisher overlay for an exact-window source is ordered directly above
  that source in the same WindowServer layer. Unrelated windows above the
  shared window therefore cover its annotations too; minimizing the source or
  leaving its Space hides the overlay. Fullscreen annotations remain a
  display-level overlay because the complete display is their source.
- Each participant has a stable identity color and visible attribution.
- A source publisher can clear all ink on its source; each participant can
  clear its own ink; all temporary drawing expires automatically.
- Viewing alone never transmits pointer position. Pointer reveal and drawing
  are explicit modes.
- Stale, malformed, excessive, unauthorized, wrong-source, and
  wrong-participant events are rejected.

Collaboration never injects keyboard or mouse input into another Mac. Remote
control, persistent whiteboards, messaging, and file transfer are outside this
version.

## Stream quality and sender settings

Codec, quality, frame rate, color, performance mode, prioritization, Auto
Share, and advanced settings belong to each participant's outgoing
publication. Changing one participant's settings never changes another
participant's sender or receiver preferences.

Software VP8, VP9, and AV1 use native ScreenCaptureKit geometry. Hardware H.264
aspect-fits only sources that exceed its 4,096-pixel-side, 4,096 × 2,304 luma,
or Level 5.2 macroblock envelope; an under-limit odd dimension is cropped by at
most one final row or column at the encoder boundary.

Compatible Rec.709 is an available 8-bit SDR video-range mode. Full-range
Rec.709 uses 8-bit full-range YCbCr with VP8, VP9, and AV1; H.264 retains its
standard Rec.709 conversion. Native Display preserves standard sRGB, Display
P3, or Rec.709 descriptions through the patched WebRTC frame bridge and native
remote presentation and is the default. An unrecognized input profile falls
back to sRGB. These modes neither enable 10-bit output nor choose 4:2:0 versus
4:2:2.

Each codec has separately persisted advanced sender controls. Changes remain a
draft until **Apply**; **Back** or **Cancel** discards the draft and **Reset**
restores automatic defaults. Every codec supports a requested bitrate floor,
congestion behavior, temporal-layer count, and RTP resolution scale. Native
H.264 also exposes maximum QP, VideoToolbox quality, and keyframe interval.
Applying updates the participant's active senders without replacing established
peer connections.

H.264 is hardware encoded and geometry-capped. VP8, VP9 profile 0, and AV1 are
software encoded at native geometry. AV1 is the default codec, Native Display
is the default color mode, and Max (20 Mbps) is the default quality preset.
Thirty FPS is the default and 15 FPS is selectable. Sixty FPS may be exposed
when the hardware path supports it but is not a release requirement.

Capture-to-WebRTC pressure is bounded per peer and observable. Each peer link
favors its latest frame to prevent latency growth; one slow participant cannot
backpressure another participant's sender. Sustained overload is visible in
directional diagnostics rather than accumulating an unbounded queue.

Each published source owns one ScreenCaptureKit session and one stream of raw
frames feeding one shared `RTCVideoTrack`. The track is attached to a separate
`RTCRtpSender` on every remote peer connection, so standard libwebrtc owns one
encoder and congestion controller for each source/remote-peer edge. Adding a
viewer does not create another ScreenCaptureKit session, disk recording, or
AVAssetWriter pipeline, but it does add an encoder/sender and another copy of
the outgoing network traffic. The common expected workload is two Native
participants sharing together. Four participants is the current tested
resource boundary rather than an inherent WebRTC protocol limit.

## Directional diagnostics

Diagnostics reflect actual peer-edge behavior rather than a room-wide assumed
codec or encoder:

- **Connections** lists every remote participant's connection state, P2P/TURN
  route, RTT, packet loss, ICE state, and control-channel state.
- **Your Publishing** groups each active local source by recipient because
  every peer edge has its own encoder, congestion controller, target rate,
  queue, and negotiated codec. Where the runtime exposes them, rows include
  codec, dimensions, FPS, bitrate, drops, QP, encode time, target bitrate, and
  send-queue pressure.
- Incoming media is grouped by Native publisher and includes only actual
  active tracks. A receive-only Web participant never creates an empty
  publishing or incoming-media section merely because it belongs to the
  roster.
- The codec in directional RTP statistics is authoritative. A configured
  codec label must not be presented as if it proves what a particular edge
  negotiated.

## Server-room-v4 protocol and privacy

Server-room-v4 is the only supported Live Share connection contract:

- A room has up to four unique participant identities in one complete
  service-authoritative opaque roster whose member descriptors are
  creator-signed and end-to-end encrypted.
- For `n` members, Clip creates `n × (n - 1) / 2` direct WebRTC peer
  connections: 0, 1, 3, or 6 links for one through four participants.
- Each pair has one canonical participant-pair key, one independent
  negotiation revision, four reserved random-identity video transceivers, one
  optional Opus audio track per direction, and one reliable ordered
  control DataChannel.
- The room service routes encrypted admission, targeted SDP, and ICE and
  broadcasts complete opaque roster snapshots. Source state, collaboration,
  and diagnostics use authenticated pair DataChannels. Media is never
  forwarded by the creator, service, or another participant.
- P-256 ECDH, HKDF-SHA256, AES-GCM, signed possession handshakes, bounded
  sequence spaces, and context-bound proofs protect admission and bootstrap.
  Cross-route, cross-session, cross-pair, replayed, stale, malformed, or
  unauthenticated traffic is rejected before it mutates room state.
- Roster membership, each publisher's source state, and each canonical peer
  link have independent positive revision domains. A stale update in one
  domain cannot block a newer update in another.
- Admission is transactional. A candidate is absent from the room until the
  creator returns a valid encrypted admission record and the service commits a
  newer complete roster.
- A Native-Web video edge offers only the publisher's selected H.264, VP8,
  VP9, or AV1 codec. It never falls back, transcodes, or starts a simultaneous
  second-codec encoding for that edge. Native-Native edges retain the proven
  pre-Web SDP preference ladder: AV1 prefers AV1, VP9, then VP8; VP9 prefers
  VP9 then VP8; H.264 and VP8 are exact. That ladder negotiates one active
  codec for the edge; each remote peer edge still owns its own standard
  libwebrtc encoder and RTP sender. It is not permission to encode several
  codecs on one edge at once.
  Actual per-link RTP statistics identify the negotiated codec and route.
- If a web runtime cannot decode the selected codec, the participant remains
  in the authoritative roster. The affected source reports **Unsupported
  Encoding: CODEC** when the codec is observable before negotiation fails;
  otherwise that peer's video may remain unavailable or black. Current
  libwebrtc may reject that incompatible peer connection as a whole, so web-v1
  does not promise audio or a DataChannel on that one edge. Other mesh edges
  and the publisher's encoders for other peer edges remain unchanged.
- SDP, ICE, decrypted messages, source count, collaboration cadence, strokes,
  queued control data, and native media pressure have explicit hard bounds.
- Validated STUN/TURN configuration supports remote traversal. TURN carries
  encrypted WebRTC traffic and gains no room authority.

The service sees the non-authorizing presentation code when serving the web
page, plus bounded random routing identifiers, ciphertext size, sequence,
nonce, timing, and network metadata. It can deny service and observe
traffic shape, but cannot prove an invite or Access Word, forge a valid member
descriptor, decrypt
signaling, or access media.

No recording is written to History during Live Share. Raw frames, PCM audio,
and network encodings are transient. Leaving removes exactly the departing
participant's links, local capture, remote presentations, audio,
collaboration overlays, statistics, and routes. Ending the room removes all
room state.

The release is intentionally server-room-v4-only. Obsolete connection,
legacy-browser, upgrade, mirroring, handoff, and codec-fallback paths are
removed rather than retained for compatibility. Existing implementation may
remain only when it is a protocol-neutral building block that the v4 session
still requires; implementation convenience alone is not a reason to retain a
legacy path, wire type, role model, entry point, UI, server route, asset, or test.

Unavailable options should be hidden. For example, `Display 2` should only appear when a second display is connected.

Every clickable popover row must show immediate hover feedback and use the
pointing-hand cursor so the action about to be selected is unambiguous.

Clip remembers:

- The most recently used capture mode.
- The most recently selected area.
- Audio settings.
- Click-highlight visibility.
- Frame-rate preference.
- Last successful first-preview resolution and CRF, plus the next capture bitrate.

The floating Preview remains visible when Clip deactivates or Capture Mode
starts. A Preview that is already open does not block a new selection or
recording. Completed capture and processing jobs remain durable while Clip
finishes the previous Preview. Before replacing a first Preview, Clip commits
its complete processed Source and non-destructive edits. A deferred Preview
must never be reported as a failed recording.

Choosing **Quit Clip** immediately closes the popover and all Clip-owned
windows and overlays, removes the menu-bar item, stops UI-producing background
work, and prevents late startup or capture tasks from reopening UI. Clip then
gets a best-effort grace period of at most eight seconds to finalize an active
recording, persist Preview state, and release managed sessions. An in-flight
first video frame is offered to the capture writer for authoritative
finalization rather than being discarded merely because its UI event is still
queued. AppKit receives exactly one termination reply. If cleanup does not
finish within the grace period, Clip exits without leaving frozen UI and uses
its durable capture/history recovery state on the next launch.

---

# Capture modes

## Capture Area

Choosing **Capture Area…** activates Capture Mode.

During Capture Mode:

- All connected displays are covered by transparent selection overlays.
- The screen outside the selected region is dimmed.
- The cursor becomes a crosshair.
- The user draws a rectangular capture region by pressing at one corner and
  smoothly dragging to the opposite corner.
- A new region begins at the exact mouse-down position and follows the pointer;
  Clip does not create an initial minimum-sized rectangle or warp the pointer.
- The selected region remains undimmed.
- The region displays resize handles.
- The region can be moved or resized before recording begins.
- A capture region belongs to exactly one display and cannot span display boundaries.
- Dragging or resizing is constrained to the selected display.

A compact toolbar appears next to the selected region.

Example:

```text
1440 × 900

Microphone: Off
System Audio: Off

Cancel     Record
```

Keyboard controls:

```text
Return     Start recording
Escape     Cancel Capture Mode
Tab        Move focus between the region, handles, and toolbar
Arrow keys Move the focused region or resize the focused handle by 1 pixel
Shift      Increase keyboard movement to 10 pixels; preserve aspect ratio while dragging
```

The toolbar must position itself outside the selected region whenever possible so that it does not cover the content being recorded.
The Cancel and Record buttons use the pointing-hand cursor; the surrounding
selection surface continues to use the capture crosshair and resize/move
cursors appropriate to its current interaction.

---

## Last Area

The **Last Area** preset immediately restores the most recently used capture rectangle.

It reopens Capture Mode with that rectangle ready for adjustment; it does not begin recording automatically.

This is particularly important for repeated recordings of:

- A browser viewport.
- An application preview.
- An iOS Simulator.
- A fixed section of an ultrawide display.
- A development environment.

The region is stored using its display identity and normalized coordinates.

If the original display is unavailable, Clip moves and clamps the region to the main display, then allows the user to adjust it before recording.

---

## Capture App

Choosing **Capture App…** opens an application-selection overlay on every
connected display.

- Moving the pointer over a visible application highlights all of that
  application's visible windows on that display.
- Clicking selects the application under the pointer. The user confirms with
  Record or Return; double-click may confirm immediately.
- Clip records the union of all visible windows belonging to the selected
  application on the clicked display. It does not capture only the single
  window that was clicked, and it does not include that application's windows
  from other displays.
- Clip's own windows and selection UI remain excluded.
- Escape and Cancel leave application selection without starting a recording.
- The selected application and display are stored as the durable target so
  Retake can resolve the application again when it is still available.

Individual-window recording remains outside the current recording scope.

---

## Fullscreen

The **Fullscreen** preset records an entire display.

If multiple displays are connected, the user selects the display before recording.

Fullscreen includes the display's menu bar and Dock. Clip's own windows, popovers, overlays, and sounds are excluded from every capture mode.

---

## Display presets

The menu-bar popover lists connected displays, such as:

```text
Display 1 — 5120 × 1440
Display 2 — 2560 × 1440
```

Selecting a display prepares it as the capture target.

Selecting a display does not immediately begin recording. The user starts the countdown with the Record button, Return key, or configured global shortcut.


---

# Starting a recording

After selecting a capture target, the user may start recording through:

- The Record button.
- The Return key.
- A configurable global shortcut.
- The menu-bar popover.

A countdown may appear before recording starts.

Default:

```text
3
2
1
```

The countdown is visual and silent. Settings offers Off, 1, 3, and 5 seconds.

---

# Recording state

While recording:

- The Clip menu-bar icon changes to indicate an active recording.
- The elapsed recording time is visible in the menu-bar popover.
- The app remains usable without showing a floating controller over the recording.
- For Capture Area, the selected rectangle remains visible as a clear,
  click-through border while recording.
- The rest of the screen is no longer dimmed once recording begins.
- The border is a Clip-owned, capture-excluded overlay and therefore does not
  appear in the resulting video.

The menu-bar popover changes to:

```text
● Recording 00:18

Pause
Finish Recording
Cancel Recording
```

Keyboard shortcuts:

```text
Option + Command + R   Enter Capture Mode
Option + Command + S   Finish recording
Option + Command + P   Pause or resume
Escape                 Cancel before recording begins
```

The three global shortcuts for Capture, Finish, and Pause or Resume are configurable. Contextual keyboard controls inside Capture Mode remain fixed.

---

# Recording controls

Clip has no hard recording-duration limit. It is optimized for short clips and should support recordings of at least 30 minutes, stopping early only when capture cannot safely continue.

## Pause and resume

The user can pause and resume recording.

Paused time must not appear in the final video.

Audio and video should remain synchronized after resuming.

---

## Finish

Finishing the recording stops capture and opens the preview window.

---

## Cancel

Canceling during a recording discards the recording after a brief confirmation when meaningful content has already been captured.

Recordings three seconds long or shorter may be discarded immediately. Longer recordings require confirmation.

---

# Audio

Clip supports:

- No audio.
- Microphone only.
- System audio only.
- Microphone and system audio.

Audio is disabled by default.

The most recently selected audio configuration is remembered.

Clip must clearly communicate when additional macOS permissions are required.

The MVP uses the current system-default microphone input device. Settings may show its name as read-only status.

Explicit microphone-device selection may be added later.

When both microphone and system audio are enabled, the temporary HEVC recording
retains two independent tracks. Initial processing mixes them once into a
compatible AAC track, preserving delayed starts and gaps as silence. Drag,
Copy, and Save As preserve that processed audio or remove it without re-encoding video. If an audio source becomes
unavailable, video recording continues with the remaining sources and Clip
reports the change.

---

# Video capture

## Default recording configuration

The default recording configuration is:

- MP4 container with hardware HEVC Main video at a 10 Mbps average target.
- 30 frames per second, with optional 60 FPS in Settings.
- Full captured backing pixels, including the display's macOS HiDPI scaling;
  no fixed 1,080p or 4K capture envelope and no silent downscale.
- SDR sRGB transfer with BT.709 primaries and matrix, normalized from the
  capture buffer's actual color profile.
- Cursor visible; audio and click highlights disabled unless enabled.
- No webcam or keystroke overlay.

On Stop, Clip processes the full recording to software x264 H.264 at CRF 24.
Native resolution is the initial default. First Preview permits 75%, 50%, and
25% scales and a CRF from 18 to 40; subsequent captures remember the most recent
successful choices. Recording bitrate in Settings changes the next recording,
not the already captured original. Processing preserves original frame timing
rather than interpolating or deliberately decimating frames.

---

## Cursor and click highlights

The user can choose whether the cursor is visible in recordings.
The user can also enable ScreenCaptureKit's native click highlights, which
draw a visible click indicator into the recorded video. Cursor visibility and
click highlights are independent choices; Clip does not require Accessibility
permission or synthesize a custom cursor overlay.

Default:

```text
Show cursor: On
Click highlights: Off
```

The menu-bar popover exposes Click Highlights as a persistent quick toggle
alongside Microphone and System Audio. The selected value is frozen into each
recording session and its History snapshot, and Retake restores that value.
Custom cursor enlargement and non-native cursor effects are not part of the MVP.

---

# Preview and editing

When recording stops, Clip opens a compact floating preview window.

The preview contains:

- Video playback in a top preview surface that acts as the exported-file drag source.
- Play and pause.
- Current time.
- Total duration.
- A simple timeline below the video preview.
- **Trim** to reveal the range handles, with **Save Trim**, **Cancel**, and **Reset Trim** while editing.
- An editable filename stem; Clip supplies the `.mp4` extension once.
- Actual processed dimensions and size.
- First-preview Resolution and CRF menus (18–40, default 24), grouped and aligned beneath their labels. Recording bitrate lives in Settings → Recording and applies to new recordings.
- An enlarged native playback window, with fullscreen support.
- A **Remove audio** switch when the recording contains audio.
- Delete, Retake, Save As, and Copy actions below the timeline and export details.

Dragging the video preview drags the current trimmed and exported MP4 as a file. The timeline itself remains dedicated to seeking and trimming and is not the file drag source.

The window appears immediately after Stop and shows progress while finalizing,
processing, and validating. Playback, trim, filename/audio edits, drag, Copy,
Save As, and Retake remain disabled until the requested processed version is
ready. Resolution and CRF menu selections process the retained HEVC
original again. Progress uses native materials and honors Reduce Motion.

Closing the first Preview commits the complete processed H.264 Source, then
removes the temporary HEVC and other candidates. Trim and audio removal remain
non-destructive metadata. Reopened Sources show their actual resolution and
support trimming and sharing, with no resolution or CRF controls.

The timeline normally hides the trim handles and shows the saved playable range
in blue, with excluded portions still visible. Playback and seeking stay within
that range. **Trim** opens a draft selection. **Save Trim** prepares the trimmed
MP4 without recompression and shows progress before enabling Copy and drag;
both reuse that prepared file. **Cancel**, closing Preview, or quitting discards
an unsaved trim draft. The complete Source stays intact.

The size shown is measured from a complete output. Changing trim or audio
removal clears the previous export size until preparation completes; no file-size
ceiling is promised by CRF.

Example:

```text
┌─────────────────────────────────────┐
│                                     │
│      Video preview · drag file       │
│                                     │
├─────────────────────────────────────┤
│ |◀──────────────────────────────▶|  │
│ 00:02                         00:24  │
│                                     │
│ clip-20260717-104218.mp4             │
│ Native ▾   CRF 24       11.5 MB     │
│                                     │
│ Delete   Retake   Save As…   Copy   │
└─────────────────────────────────────┘
```

---

## Editing scope

The MVP editor supports:

- Playback.
- Trimming from the beginning.
- Trimming from the end.
- Restoring the original trim.
- Retaking the recording.
- Deleting the recording.
- Renaming the recording and exported file.
- Removing or restoring all recorded audio for playback and exported files.
- Dragging the video preview to another application as an MP4 file.

Retake reuses the previous target, audio, and countdown settings. Clip keeps the previous recording until the replacement succeeds, then discards the old draft.

**Remove audio** is a non-destructive, per-recording Preview/export choice. It
is Off by default for both new recordings and history created before the field
existed. Turning it On mutes Preview playback immediately, removes the audio
track from Drag, Copy, and Save As output. Turning it Off restores playback and
exported audio.
The choice persists through Done, sharing, History, Preview reopen, and app
relaunch. It never removes or rewrites audio in the managed recording master.

The MVP does not support:

- Splitting clips.
- Joining recordings.
- Text overlays.
- Shapes or arrows.
- Blur regions.
- Zoom effects.
- Transitions.
- Speed changes.
- Audio-level, per-source, or timeline audio editing.
- Multi-track editing.

---

# Export and sharing

Clip has two equally supported sharing actions: dragging the video preview and selecting **Copy**. There is no automatic-copy-after-stopping feature or setting.

## Drag video

Dragging the top video preview supplies an MP4 file using the current trim,
editable filename and Remove audio choice. The file can be
dropped into Finder or another application that accepts file drags. The drag
payload advertises both the MPEG-4 representation and the resulting local file
URL so Finder and browser upload targets can consume it directly. Every
destination receives the current edited filename; macOS must not substitute a
generic name such as `MPEG-4 movie.mp4`.

## Copy

When **Copy** is selected, Clip:

1. Reuses the file prepared by **Save Trim** when its source generation, range,
   filename, and audio choice still match.
2. Otherwise copies the complete processed H.264 file or remuxes the selection,
   without another quality-compression pass.
3. Applies the recording's current Remove audio choice, with no audio track
   when removal is selected.
4. Places the resulting file URL on the macOS clipboard.
5. Shows a completion confirmation.

Example:

```text
✓ Video copied — 5.8 MB
```

The user should then be able to paste the video directly into applications that accept copied files, including:

- Slack.
- GitHub issues and pull requests.
- Linear.
- Discord.
- Messages.
- Mail.
- Finder.
- Other applications that accept copied files.

Clip considers the operation successful when it has written a valid, readable MP4 file to the pasteboard. macOS does not tell Clip whether a different application later accepted or rejected a paste.

---

## Save As

The user can save the exported recording to a chosen location. Save As uses the
same trim, filename, and Remove audio choice as Drag and Copy.

The default filename format is:

```text
clip-20260717-104218.mp4
```

The filename is editable in Preview and History. The `.mp4` extension is preserved automatically. Save As creates an independent external file that Clip never removes through history cleanup.

The default format is editable in Export Settings. It supports the
case-sensitive fixed-width tokens `YYYY`, `MM`, `DD`, `HH`, `mm`, and `ss`,
shows a live example, and rejects formats that could produce an unsafe path or
invalid MP4 filename. Existing settings created before this option migrate to
the default format above.

Save As always uses the standard macOS Save panel. Choosing a destination such
as Downloads grants Clip access to that exact output URL through the App
Sandbox Powerbox; Clip must not fail merely because the destination is outside
its container, and it must not request broad permanent access to the parent
folder. Canceling the panel makes no filesystem change.

---

## Reveal in Finder

After export or save, the user can reveal the file in Finder.

---

# Recording processing and sharing

Capture and sharing have separate jobs. Hardware HEVC records full backing
pixels efficiently at a default 10 Mbps target. After Stop, software x264
processes that original once to a compact H.264 MP4 suitable for GitHub, Slack,
and ordinary native playback. The initial defaults are Native resolution and
CRF 24. A 30–60-second demo under 25 MB is a goal, not a guaranteed limit;
content, motion, dimensions, and CRF determine the final size.

The first Preview provides a Resolution menu (Native, 75%, 50%, 25%) with pixel
dimensions, and a CRF menu (18–40, default 24; lower retains more detail). Existing
saved values outside that menu remain selectable. Native preserves
all captured pixels; reduced sizes use Lanczos and even dimensions. Every
reprocessing request reads the retained HEVC original. A prior H.264 candidate
is never used as the input to another compression pass. Only validated,
successful choices become the defaults for the next recording.

Close commits the latest complete full-duration H.264 as the managed Source.
The private original is deleted only after the Source and metadata are durable.
Exports remain independent files in their own locations and never replace a
Source. Reopening a Source permits restoring its full trim and audio, but
cannot recover resolution or detail discarded during initial processing.

Full-duration, unchanged exports are independent byte-for-byte copies. Trim
and audio-removal exports use native compressed passthrough and edit lists;
they do not encode the video again. A non-keyframe trim must display the
selected first frame, preserve its pixels, and maintain audio alignment.
Existing recordings remain readable and use the same copy/remux export path.
Old Apple 0–100 quality values are not interpreted as CRF.

The temporary original and generation journal survive interrupted processing.
Failed processing never deletes the previous valid result. Close, Quit, and
startup recovery share a durable commit boundary. External deletion of a
session or its journal must not trap the window in a loading state; remaining
recoverable media is retained and a completely empty session can close.

---

# Recent recordings

Clip maintains a small local recording history.

The menu-bar popover shows recent recordings:

```text
Recent Recordings

clip-20260717-104218      3.8 MB
dashboard-filters        7.1 MB
mobile-navigation        2.4 MB
```

New recordings use the timestamp filename by default. The user may rename them in Preview or History.

Each recording supports:

- Preview.
- Rename.
- Copy.
- Save.
- Reveal in Finder.
- Delete.

The full History window uses native **Recordings** and **Exports** tabs.
Recordings show any still-live Copy or drag exports linked to that source as
compact chips below the row; each chip can be revealed in Finder or deleted.
The Exports tab inventories every still-live Copy and drag export, shows its
dimensions, size, and source relationship, and supports Reveal, individual Delete,
and Delete All. If the source recording has been removed, its export remains in
the Exports tab with a visible **Source deleted** state and is no longer shown
under a recording row.

Recordings remain local.

Default retention:

```text
7 days
```

Retention options:

- 1 day.
- 7 days.
- 30 days.
- Keep indefinitely.

Clip should clearly show how much storage its history is using.

## History storage model

- A durable processing session is created after Stop. Closing its first Preview
  commits the complete processed Source to History.
- Clip keeps that full Source plus non-destructive trim, filename, audio-removal
  metadata, and the recorded processing recipe.
- Copy and drag create managed temporary exports.
- Save As creates an independent external file that Clip never deletes.
- Only exports actually published by Copy or drag appear in the Exports tab;
  an internal cache file produced while completing Save As is not listed.
- Recording retention, recording deletion, and Clear History remove managed
  masters but retain live Copy and drag exports. Those exports can be removed
  independently from the Exports tab and otherwise expire through the
  ownership-aware seven-day cache cleanup.
- Cleanup age is based on recording creation time.
- The history location is fixed under Application Support and can be revealed but not relocated.

---

# Settings

The settings window contains the following sections.

The first presentation explicitly selects **General** and must render every visible label,
control, and current value immediately. Opening Settings must not depend on leaving and
returning focus to complete SwiftUI layout or drawing.

General, Recording, Live Share, Export, Storage, and Permissions are presented as an always-visible
native macOS top tab bar. They must not collapse into a toolbar overflow button at the
supported initial window size. Clip does not draw a custom segmented selector or glass
backdrop for these tabs; the system `TabView` supplies the current native appearance,
including Liquid Glass where macOS applies it. Forms scroll vertically when their contents
exceed the window; controls and labels remain single-line where practical.

## General

- Launch Clip at login.
- Show Clip in Dock.
- Default capture mode.
- Remember last selected area.
- Global keyboard shortcuts.

---

## Recording

- Frame rate: 30 or 60 FPS.
- Countdown duration.
- Show cursor.
- Show click highlights.
- Default microphone state.
- Default system-audio state.
- Current system-default microphone name, shown read-only.

---

## Live Share

- An editable, validated server base address.
- A non-destructive Test Connection action that does not reserve a room.
- Reset Server Address, restoring the built-in Clip Live Share service address.
- This device's persistent Live Share identity fingerprint, plus a destructive
  Reset Identity action. Reset is unavailable while the identity belongs to an
  active room.
- Default video codec, quality/bandwidth rung, frame rate, and Performance or
  Quality encoding mode.
- Per-codec advanced stream defaults with Apply and Reset, including shared
  sender controls and H.264-specific VideoToolbox controls.
- Default System Audio, Access Word requirement, Prioritize Focused Window, and
  Auto-share Focused Windows states.
- Default Fullscreen app-audio exclusions.
- Default collaboration pointer visibility, ping duration, ink color, and
  automatic ink expiry.
- Restore All Live Share Defaults, restoring session defaults without changing
  the separately managed server address.

Server-address changes apply when the next Live Share session starts and never
retarget an active session.

---

## Export

- Default filename format in a clearly bordered editable field. The editor contains only
  the filename template stem; a fixed, non-editable `.mp4` suffix is shown beside it and
  appended automatically. The field's accessible label must not also render as duplicate
  visible prompt text.
- Automatically close preview after copying.
- Default Save As location.

---

## Storage

- Recording-history location, shown read-only with Reveal in Finder.
- Current storage usage.
- Clear recording history.
- Recording history retention and automatic cleanup policy.

---

## Permissions

A dedicated permissions section shows status for:

- Screen Recording.
- Microphone.
- System Audio, where applicable.

Each permission should include a button that opens the relevant macOS System Settings page.

## Initial defaults

- Launch at login: Off.
- Show in Dock: Off.
- Capture mode: Capture Area.
- Remember Last Area: On.
- Frame rate: 30 FPS.
- Show cursor: On.
- Click highlights: Off.
- Microphone: Off.
- System audio: Off.
- Countdown: a silent 3 seconds, with Off, 1, 3, and 5-second choices.
- Live Share server: `https://clip.tineestudio.se`.
- Live Share video: AV1, Max quality (`20 Mbps` ceiling), 30 FPS, Quality mode,
  Native Display color.
- Live Share System Audio: Off.
- Live Share Access Word: Off.
- Live Share Ask Before Joining: Off; verified full invites auto-admit, while
  friend joins always require Allow or Deny.
- Live Share Prioritize Focused Window: On.
- Live Share Auto-share Focused Windows: Off.
- History retention: 7 days.
- First-preview resolution: Native (full captured backing pixels).
- Initial processing CRF: 24.
- Capture bitrate: 10 Mbps HEVC.
- Automatically close preview after Copy: Off.
- Default Save As location: `~/Movies`.
- Canonical/output filename format: `clip-YYYYMMDD-HHmmss.mp4`; the Settings editor shows
  `clip-YYYYMMDD-HHmmss` with the protected `.mp4` suffix beside it.
- Appearance: the current macOS light or dark appearance.

---

# Permissions onboarding

On first launch, Clip displays a short onboarding flow.

## Step 1

Explain what Clip does.

```text
Record a selected area of your screen, then drag or copy a compact video in seconds.
```

## Step 2

Request Screen Recording permission.

## Step 3

Optionally explain microphone and system-audio permissions.

## Step 4

Offer to configure the global shortcut and launch-at-login preference.

The application uses the permanent bundle identifier `com.tomaslejdung.clip`. The owner's local release is signed with the Apple Development certificate from free Personal Team `FJ2BS65H3F`; a paid Apple Developer membership is not required for this local-only workflow. This gives rebuilds a stable macOS privacy identity. Permission-free CI may still use ad-hoc signing, but those builds can require fresh approvals whenever their code identity changes.

---

# Error handling

Clip must handle the following cases gracefully:

- Screen Recording permission denied.
- Microphone permission denied.
- A display disconnects during recording.
- The capture area becomes invalid.
- Available disk space becomes low.
- Encoding fails.
- The application quits unexpectedly.
- Clip cannot place a valid, readable MP4 file URL on the clipboard.
- A recording contains no frames.
- Audio and video input become unavailable.

When a display disappears, disk space becomes critical, or capture fails, Clip should safely finalize and preserve playable material where possible. Interrupted recordings should be recovered on the next launch where technically possible. Protected or DRM-controlled screen and audio content may remain unavailable by macOS design.

Clip may offer troubleshooting when another application does not accept a paste or drop, but it cannot observe or report that destination application's result.

Error messages should explain what happened and what the user can do next.

Raw technical errors should be available through a details or logs view but not shown as the primary message.

---

# Performance goals

Clip should target:

- Menu-bar popover opening instantly.
- Capture Mode appearing with p95 latency under 300 milliseconds.
- Recording beginning immediately after the countdown.
- Minimal CPU use while idle.
- Hardware-accelerated capture and encoding.
- Preview shell visible immediately after Stop, with progress until processing completes.
- Stop-to-ready processing under ten seconds for the defined 30-second, 1,440 × 900, 30 FPS synthetic fixture on the development Mac.
- Independent copy export of that processed fixture under two seconds.
- Trim timing accurate to within one frame.
- Audio and video synchronization within 50 milliseconds, including across pause and resume.
- A ten-minute real recording soak test plus longer synthetic state and writer tests.
- Stable long-running menu-bar behavior.
- No noticeable interference with the application being demonstrated.

---

# Privacy

Clip's recording workflow is local-first. Recording, Preview, History, and
exports do not upload media. Live Share is the only feature that transmits
captured media: when the user starts a room, selected transient screen frames,
optional system audio, and control metadata leave the Mac over encrypted
WebRTC. Sparkle may separately contact the configured update feed to check for
new application releases. The room service sees room/routing metadata and
bounded end-to-end-encrypted signaling envelopes, not plaintext admission,
SDP, ICE, stream/control data, or media.
It can observe IP addresses, timing, room size, opaque identifiers, ciphertext
sizes, and traffic shape, and it can deny service. TURN may relay encrypted
WebRTC packets but gains no room authority or media plaintext.

The room-service origin supplies the receive-only Web viewer JavaScript. A
malicious or compromised origin could serve modified code that reads the invite
fragment, so fragment secrecy from that Web origin is not a product claim.
Native-to-Native use has the stronger separation because the service does not
supply either Native client. Users may self-host the service and viewer to
control that origin.

The recording workflow includes:

- No user account.
- No cloud upload.
- No analytics by default.
- No AI processing.
- No remote processing.
- No recording data leaving the Mac unless the user explicitly starts Live
  Share; a Live Share is not saved as a recording.

Any future telemetry must be optional and transparent.

---

# Technology stack

## Language

- Swift 6 language mode using Apple Swift 6.3.3.

## Target platform

- Xcode 26.6, build 17F113.
- macOS 15.0 or later deployment target.
- Apple Silicon (`arm64`).

## User interface

- SwiftUI for:
  - Menu-bar popover.
  - Settings.
  - Preview controls.
  - Recording history.
  - Onboarding.

- AppKit for:
  - Capture overlays.
  - Transparent full-screen panels.
  - Floating preview windows.
  - Multi-display coordination.
  - Global keyboard handling.
  - Lower-level macOS window behavior.

## Capture

- ScreenCaptureKit.

Used for:

- Display capture.
- Region capture.
- Cursor capture.
- Native click highlighting.
- System audio.
- Efficient frame delivery.

## Video and audio

- AVFoundation and AVPlayer for native inspection, playback, and trim/remux.
- VideoToolbox for hardware HEVC capture.
- AVAssetWriter for passthrough HEVC muxing and AAC capture tracks.
- An app-bundled, signed, standalone FFmpeg 8.0 / x264 r3222 helper for initial
  H.264 processing. No Homebrew, Python, runtime download, or network protocol
  is required. The helper inherits the app sandbox and links only system dylibs.

### Capture contract

- One exact even-sized geometry derived from the display's ScreenCaptureKit
  backing scale is used for source rectangle, stream output, encoder, and MP4.
- Each complete incoming buffer is checked for the configured dimensions.
  Unexpected geometry fails visibly; capture never silently resizes frames.
- The buffer's actual color profile is normalized to sRGB without changing
  dimensions. Unknown color profiles are rejected instead of relabeled.
- HEVC Main uses hardware acceleration, real-time encoding, a default 10 Mbps
  average target, no frame reordering, and a two-second keyframe interval.
  Unsupported hardware geometry fails clearly rather than switching to 1×.
- VideoToolbox-compressed samples pass through AVAssetWriter unchanged, alongside
  native AAC tracks. Raw pixel buffers are transient; at most the latest frame
  is retained for bounded cadence repair and the final static hold.
- Brief encoder pressure is bounded; sustained pressure or dropped frames fail
  visibly. Pause time is removed from video and audio. Static content retains
  its final Stop boundary, including after a pause/resume sequence.
- A 60,000-tick MP4 clock preserves 30/60 FPS exactly and supports long static
  sample durations without overflowing the container's sample delta field.

### Processing and export contract

- Stop triggers hardware HEVC decode and software x264 encoding with `veryfast`,
  four threads, CRF 24 by default, no B-frames, one reference frame, High profile,
  4:2:0 pixels, and MP4 fast start. Native has no resize filter; reduced choices
  use Lanczos. Original timestamps and the final sample duration are preserved
  within one output timebase tick.
- Preserve SDR transfer/primaries/matrix. A single AAC track passes through;
  multiple tracks are aligned by timestamps and mixed once to 128 kbps AAC.
- Inspect source and candidate natively, require dimensions, sample count,
  duration, codec, audio count, and color to match the recipe, and decode the
  first and last frames before publishing the candidate atomically.
- Cancellation terminates and waits for the helper before removing partial
  output. It never removes the original or an already complete result.
- Closing first Preview persists the full untrimmed processed Source with its
  recipe and metadata. Only then are its private original and candidates deleted.
- Full unchanged exports independently copy bytes. Trim or mute uses AVFoundation
  compressed passthrough with native first-frame and duration validation.
  Ordinary sharing never changes resolution, CRF, or Source ownership.
- Reopened Sources have no processing controls. Existing Sources remain readable;
  no compatibility branch recreates removed quality-preset encoders.

## Persistence

- Versioned JSON under Application Support for user preferences, with atomic replacement and backward-compatible defaults.
- Versioned JSON metadata for the initial recording-history index.
- Managed processed Sources, capture staging, unfinished processing jobs, and
  atomic journals under Application Support.
- Temporary clipboard, drag, and intermediate export files under Caches.

SQLite is not required for the MVP unless the recording-history model grows significantly.

## Package management

- Swift Package Manager.

The two audited Swift Package runtime boundaries are:

- Sparkle 2, pinned exactly for update discovery, download, verification,
  installation, and relaunch.
- WebRTC M150, pinned to one upstream source commit plus Clip's reviewed color
  patch and published as an immutable checksummed arm64 XCFramework behind
  `Packages/ClipLiveShareWebRTC`, for ICE, DTLS-SRTP, SCTP DataChannel,
  congestion control, Opus system-audio transport, and hardware-H.264 plus
  software-VP8/VP9/AV1 native mesh transport.

WebRTC is a media-transport runtime. Recording processing uses the separate
static FFmpeg/x264 executable built from pinned, checksummed upstream sources.
Its exact source archives, build recipe, GPL notices, and licenses ship inside
the app. Packaging verifies its architecture, inherited sandbox entitlements,
signature, system-only dependencies, and payload/source provenance. Test-only
dependencies should be avoided unless they improve deterministic verification. Publishable DMGs resolve Sparkle and the reviewed WebRTC binary
in a fresh isolated package cache, compare the embedded WebRTC payload with
that artifact, and include complete third-party notices; ignored development
package state is not accepted as release provenance.

## Live Share service deployment

- The top-level `server/` folder is an independent Go 1.25 module containing
  the bounded opaque server-room-v4 roster registry and encrypted signaling
  relay, tests, Dockerfile, and Docker Hub publication script.
- The service owns the authoritative opaque participant roster, socket
  presence, reconnect grace, and pair-signal routing. It owns no plaintext
  identity, admission secret, source state, or media state.
- Server room state is in-memory and intentionally single-replica for the first
  v4 release. A restart clears room state. Existing WebRTC peer links may stay
  connected temporarily, but every client terminates the room after a bounded
  signaling outage rather than inventing membership.
- Internet deployments terminate TLS at a reverse proxy and expose HTTPS/WSS.
  The Web client rejects non-loopback HTTP invites; only exact loopback hosts
  are allowed for local development. The service publishes validated
  ICE-server capabilities to participants.
- The container is CGO-free, non-root, health-checked, and published for
  `linux/amd64` and `linux/arm64` with Buildx provenance and SBOM metadata.
- The Go service is deployed separately and is never bundled in `Clip.app` or
  launched as a local helper. Users can select the hosted default or configure
  a self-hosted endpoint in Live Share Settings.

## Development environment

- Source editing can be done in Codex, Cursor, VS Code, Zed, or another editor.
- Xcode 26.6 and Apple command-line tools provide the macOS 26.5 SDK, Swift 6.3.3, local signing, building, and DMG creation.
- Go 1.25 provides the local server-room-v4 acceptance lane; Docker Buildx
  is required only to publish the service image.
- The project should support command-line builds.

## Security configuration

- App Sandbox enabled.
- Hardened Runtime enabled.
- Entitlements limited to the capabilities Clip actually uses, including
  microphone input, user-selected file access, outbound networking for Sparkle
  and Live Share, and inbound networking required by WebRTC ICE connectivity.
- The sandboxed Sparkle installer receives only its documented
  installer-service and mach-lookup exceptions. Live Share networking remains
  inside Clip and does not launch a Go or media helper process.
- No Accessibility permission is requested.


---

# Distribution

Clip is a personally maintained direct-download application distributed from
the public GitHub repository's Releases page. It is not an App Store release.

The distribution artifact is:

```text
Clip.dmg
```

Installation:

```text
Open Clip.dmg
→
Move Clip.app to Applications
→
Open Clip
→
Grant Screen Recording permission
```

Release requirements:

- Permanent bundle identifier `com.tomaslejdung.clip`.
- Local Apple Development signing with Personal Team `FJ2BS65H3F`, preserving one privacy identity across rebuilds.
- Hardened Runtime.
- App Sandbox.
- A DMG containing a launchable `Clip.app` with an Applications shortcut.
- A Sparkle EdDSA-signed update enclosure using the immutable, tag-specific
  GitHub Release DMG URL and a one-item appcast hosted by GitHub Pages.
- Mount, copy, launch, record, export, drag, clipboard, and remount smoke testing on the development Mac.

The first Sparkle-enabled Clip build is a bootstrap release and must be
downloaded and installed manually from its DMG. Builds installed before the
updater exists cannot discover it. After that bootstrap install, Clip checks
the signed appcast periodically and presents an available update through the
native Sparkle flow. **Check for Updates…** in the menu-bar popover performs the
same check on demand. Update installation downloads the signed full DMG,
relaunches Clip, and preserves the existing Settings and History directories.

The DMG is Apple Development signed for local use, not Developer ID signed or notarized. If the artifact later receives a quarantine attribute through download, messaging, or AirDrop, macOS may require a one-time **Open Anyway** approval in Privacy & Security.

Mac App Store distribution, Homebrew, Developer ID signing, and notarization
are outside the current scope.

The main source repository should simply be named:

```text
clip
```

A separate Homebrew tap can be added later if needed.

---

# Testing strategy and platform limitations

- All automated tests run locally on the development Mac; no CI service or separate test machine is required.
- Unit, integration, state-machine, media, and UI tests use injected services and deterministic synthetic frames and audio where practical.
- `--ui-scenario=<name>` fixtures are honored only with `--ui-testing`. They use isolated defaults and storage plus inert permission, audio, capture, display, pasteboard, shortcut, and external-AppKit actions; they never request privacy access or enter the real-capture lane.
- Deterministic launch fixtures cover onboarding, the populated menu-bar popover and displays, denied permissions, recording, paused recording, Preview, History, every Settings tab, and a representative failure surface. Their UI-automation assertions compile in the permission-free suite but execute only after an explicit visible-pointer-control opt-in.
- A pointer-free hosted visual lane renders the production Settings window at the top and fully scrolled bottom of every tab, writes ten PNGs plus scroll-position metadata, and fails if a scrollable form does not reach its bottom.
- Live Share's pointer-free lane builds the in-repository opaque Go room
  service, exercises real loopback HTTP/WebSocket routing, validates
  server-room-v4 encrypted admission and pair-signaling vectors, and runs the
  native protocol, mesh,
  media, and presentation suites. Deterministic coverage proves:
  - direct v4 Create Room and Join Invite with no legacy entry point;
  - invite capability and optional Access Word proof plus explicit approval;
  - signed identities, encrypted member descriptors, complete authoritative
    rosters, revision isolation, denial, reconnect grace, and bounded cleanup;
  - two-, three-, and four-participant topologies containing 1, 3, and 6
    independent authenticated peer links;
  - concurrent native publication and remote reception, four source slots,
    fullscreen exclusivity, per-participant audio, the Native compatibility
    preference ladder, exact selected-codec Web edges, explicit
    unsupported-browser reporting, directional statistics, and slow-peer
    isolation;
  - receive-only Web profiles using the same admission, roster, pair identity,
    encrypted signaling, fixed transceivers, and DataChannel contract as Native
    profiles, with no browser-specific native transport path;
  - common participant-room presentation, remote source grouping,
    Fit/Native/Follow/fullscreen, visibility/fronting, cursor mapping, pointer,
    ping, temporary ink, and exact teardown;
  - noncreator leave isolation and terminal creator leave/grace expiry with no
    election or locked phase.
  It does not touch the installed app or control the pointer.
- Real ScreenCaptureKit, microphone, system-audio, clipboard, drag, Save As, history, and DMG smoke tests run on the development Mac.
- Real Live Share acceptance separately covers the production ScreenCaptureKit
  participant path with two, three, and four independently launched signed Clip
  processes. Every participant must publish and receive concurrently, exercise
  one through four windows plus Fullscreen, independent audio and app-audio
  exclusions, Fit/Native/Follow, local fullscreen, Retina/multi-display
  placement, overlay exclusion and hit testing, pointer/ping/ink, direct/TURN
  traversal, repeated source and room churn, noncreator leave/reconnect,
  creator room termination, and a ten-minute soak. The four-participant
  gate must prove all six links. Deliberate rendezvous-service loss after peer
  establishment must not stop established media/control. A one-process model
  test cannot substitute for these signed multi-process gates.
- Application-update verification checks the embedded feed URL/public key,
  sandbox services and entitlements, nested code signatures, exact app/build
  versions, immutable enclosure URL, archive length, and Sparkle EdDSA
  signature. Once two updater-enabled releases exist, final acceptance installs
  an older build and exercises automatic discovery plus **Check for Updates…**
  through download, install, relaunch, and Settings/History preservation.
- The owner performs the required one-time Screen Recording, System Audio, and Microphone approvals. Test runs after approval should be unattended.
- Multi-display topology, display disconnection, and deterministic loopback-audio cases are simulated when the necessary hardware is unavailable.
- There is no automated Slack, GitHub, Linear, Discord, Messages, or Mail integration suite. A local receiver and Finder validate file drag and clipboard contracts; an agent-driven check in an explicitly authorized application may be performed without sending content.
- The owner approved the HEVC 10 Mbps → H.264 CRF 24 prototype visually. Automated
  production tests verify native geometry, timing, color metadata, native
  decoding, scale choices, long static holds, and delayed/gapped audio content.
  These tests do not establish a subjective sharpness score for every display.
- Exports must preserve source bytes for full copies and displayed pixels for
  non-keyframe/fractional trims. Cancellation, external deletion, atomic commit,
  startup recovery, and independent clipboard/drag ownership require regression
  coverage. No old 0–100 preset or SSIM ladder remains as an acceptance gate.
- A fresh-account privacy grant cannot be automated through supported macOS behavior.
- Clipboard and drag temporary files must remain available long enough for receiving applications to consume them and therefore cannot be removed immediately after export.
- The two-second export goal applies only to the defined performance fixture, not arbitrary native-resolution 5K/60 FPS recordings.

---

# MVP feature list

## Included in the current version

- Native menu-bar application.
- Capture Area mode.
- Capture App mode for all visible windows of the clicked application on the selected display.
- Last Area preset.
- Fullscreen capture.
- Per-display capture.
- Multi-display support.
- Movable and resizable selection rectangle.
- Menu-bar recording controls.
- Configurable global shortcuts.
- Configurable countdown.
- 30 FPS recording.
- Optional 60 FPS.
- Cursor visibility option.
- Native click-highlights option, with menu-bar quick toggle.
- Microphone capture.
- System-audio capture.
- Pause and resume.
- Cancel recording.
- Floating preview.
- Playback.
- Trim beginning and end.
- Editable timestamp-based filename.
- Rename in Preview and History.
- Non-destructive Remove audio in Preview, persisted for History and exports.
- Automatic HEVC-to-H.264 processing with progress.
- Native, 75%, 50%, and 25% first-preview resolution choices and CRF control.
- Enlarged playback with native fullscreen.
- Complete processed Sources with reversible trims and audio removal.
- Drag the exported MP4 from the video preview.
- Explicit Copy button that places the MP4 file on the clipboard.
- Save As.
- Reveal in Finder.
- Recent local recording history.
- Automatic history cleanup.
- Launch at login.
- Permission onboarding.
- Local launchable DMG distribution.
- Signed application updates from immutable GitHub Release DMGs, with periodic
  automatic checks and an on-demand **Check for Updates…** action.
- A server-room-v4-only Live Share participant mesh using the in-repository
  opaque roster/signaling service, end-to-end-encrypted admission and pair
  signaling, client-only-fragment invites, persistent device identities,
  optional Access Word, and optional creator approval.
- Up to four participants and six direct authenticated WebRTC peer links, with
  authoritative roster reconciliation, participant removal, pair-local failure
  isolation, reconnect grace, and terminal creator departure.
- One common native participant room popover. Every native member can
  simultaneously publish up to four exact windows or one mutually exclusive
  fullscreen display and receive every other native member's sources.
- A receive-only web participant served by the same-origin room service for
  current desktop Safari and Chromium. It joins the same complete mesh and
  receives every native publisher's sources and audio, but cannot publish,
  administer rooms, create friendships, or use collaboration controls.
- Native-Web edges require the selected codec exactly, with one active codec
  per edge: no browser-specific fallback, simultaneous second-codec encode, or
  transcoding. Native-Native edges preserve the pre-Web SDP preference ladder
  while still negotiating one active codec per edge. Every source uses one
  capture/raw-track pipeline but a separate libwebrtc encoder/RTP sender for
  each remote peer. Unsupported browser decoders show an
  explicit source error when the codec is observable; an edge that fails before
  that may remain unavailable or black, without changing unrelated mesh edges.
- Optional independently persisted Live Share system audio per participant,
  defaulting to Off: unique owning applications for window sharing or system
  audio for Fullscreen, excluding Clip and selected applications, sent as one
  stable Opus track. No microphone audio is sent. Each receiver has independent
  mute and volume for every remote participant.
- Per-participant remote source grouping, directional connection/statistics
  state, Fit/Native/Follow, local fullscreen, hide/reopen, per-window and
  Bring-All-to-Front actions, source-aware Retina/1× presentation, native
  cursor context, reconnect, and exact participant teardown.
- Participant pointer reveal, bounded pings, temporary attributed vector ink,
  clear and expiry controls, with no remote input injection.
- Local stream settings/statistics, focused-window Share/Stop control, status
  HUD, Auto Share, and source stop/restart without ending the room.

The recording release-critical path is: install and launch from DMG → select →
record → preview → trim → drag or copy. The independent Live Share path is:
create a server-room-v4 room → copy its stable complete invite → join with invite
and optional Access Word → auto-admit a verified full invite, or explicitly
Allow/Deny when Ask Before Joining or a friend join requires it → every
participant shares and receives windows/display/audio → exercise
pointer/ping/ink → change or stop sources independently → leave as a
participant or end as the creator.
The web-v1 path opens that same invite in a supported desktop browser → joins
the same authoritative roster → creates one direct pair per remote member →
receives all compatible exact-codec sources and per-publisher audio → exercises
Focus/Row, Follow Off and per-publisher Follow, the source filmstrip, HUD
auto-hide, Fit/Fill/Native, Native pan/minimap, fullscreen, and mute/volume → leaves or
reloads/reconnects without replacing an unaffected native pair.
A recording release may remain valid without the networking feature, but a
release advertising Live Share must pass the Live Share controlled and
packaging gates above.

---

# Deferred features

Potential later additions:

- Saved named capture regions.
- Individual-window recording (Live Share already targets exact windows).
- GIF export.
- Webcam bubble.
- Custom click animations beyond the native system click-highlight rings.
- Keystroke visualization.
- Blur regions.
- Automatic maximum-file-size encoding.
- Explicit microphone-device selection.
- Optional upload destinations.
- Homebrew Cask.
- Universal Intel support and native Intel validation.
- Developer ID signing and notarization.

These features should only be added if they support the core workflow without turning Clip into a general-purpose video editor.

---

# Explicit non-goals

Clip will not initially provide:

- Screenshot capture.
- Scrolling screenshots.
- Full video editing.
- Multi-clip timelines.
- Cloud accounts.
- Team workspaces.
- Persistent whiteboards, comments, or collaborative document editing beyond
  temporary Live Share pointer, ping, and ink overlays.
- Hosted video links.
- Mac App Store distribution.
- AI features.
- Transcription.
- Automatic zoom effects.
- Windows or Linux versions.
- Browser extensions, browser publishing, friendship, collaboration, or room
  administration. The receive-only desktop web participant is included.
- Watermarks.

---

# Product identity

## Name

**Clip**

## Application name

```text
Clip.app
```

## Executable

```text
Clip
```

## Repository

```text
clip
```

## Version

The current marketing version and build number are release metadata defined by
the Xcode project and release notes, not by this long-lived product
specification.

## Bundle identifier

```text
com.tomaslejdung.clip
```

## Copyright

```text
Copyright © 2026 Tomas Lejdung. All rights reserved.
```

The local release uses free Personal Team ID `FJ2BS65H3F`. It is not a Developer ID or App Store release.

## Positioning

> Quick screen recordings for sharing your work.

## Core promise

> Select, record, trim, drag or copy.

## Primary audience

- Software developers.
- Product designers.
- QA engineers.
- Product managers.
- Support engineers.
- Anyone who regularly shares short interface demonstrations.

## Typical use cases

- Showing a newly developed feature.
- Demonstrating a bug.
- Attaching reproduction steps to a GitHub issue.
- Sharing progress in Slack.
- Recording an interaction for a pull request.
- Showing a UI state to a designer or colleague.
- Creating a short silent product demo.

---

# Recommended implementation order

## Phase 1 — Application foundation

- Create Clip.app.
- Add the menu-bar icon.
- Set the permanent bundle identifier.
- Establish stable local Apple Development signing, an ad-hoc CI fallback, and the sandbox entitlements.
- Request and retain Screen Recording permission.
- Produce and launch a test DMG on the development Mac.

## Phase 2 — Capture

- Enumerate displays.
- Implement fullscreen recording.
- Implement rectangular selection.
- Implement application selection and all-visible-window application capture.
- Add Last Area.
- Capture native pixels to temporary hardware HEVC MP4.
- Process once to the final H.264 Source with the bundled encoder.
- Add recording controls.

## Phase 3 — Preview and sharing

- Build the preview window.
- Add playback.
- Add start and end trimming.
- Add editable filenames and rename.
- Add non-destructive Remove audio playback/export state.
- Make the top video preview the exported-file drag source.
- Add Copy.
- Add Save As.
- Add first-preview resolution and CRF, processing progress, and enlarged playback.
- Commit the full processed Source on Close and recover interrupted sessions.

## Phase 4 — Audio and history

- Add microphone capture.
- Add system audio.
- Add recent recordings.
- Add cleanup and retention.

## Phase 5 — Polish

- Improve multi-display behavior.
- Add launch at login.
- Improve error handling.
- Optimize file size and export performance.
- Produce and verify the local launchable DMG.

## Phase 6 — Native participant mesh

- Replace all Live Share creation and joining with direct server-room-v4
  participant sessions.
- Add stable client-only invite capability, Access Word, optional explicit
  admission, creator-signed encrypted descriptors, authoritative opaque
  rosters, complete-mesh peer links, and bounded participant lifecycle.
- Give every participant the same local sharing controls and one remote
  presentation per other participant.
- Add per-participant audio, source grouping, diagnostics, pointer, ping, and
  temporary ink.
- Prove two-, three-, and four-participant operation before publishing the
  v4 release. Remove obsolete connection protocols and role-specific
  entry paths rather than shipping compatibility code.

## Phase 7 — Receive-only web participant

- Serve a same-origin repository-owned web client from the v4 room service.
- Join with the canonical fragment-secret invite and advertise the authenticated
  `webViewer/webViewerV1` profile.
- Reuse the same roster reconciliation, pair identity, encrypted signaling,
  fixed media slots, and DataChannel contract as Native participants.
- Receive every compatible native source and per-participant system-audio
  track with Focus/Row, Follow Off and per-publisher Follow, filmstrip source
  selection, HUD auto-hide, Fit/Fill/Native, Native pan/minimap, fullscreen,
  and audio controls.
- Enforce the selected codec exactly on Native-Web edges with no simultaneous
  second-codec encoding, transcoding, or fallback, and report unsupported
  browser decoding explicitly. Preserve the pre-Web Native-Native SDP
  preference ladder and one active codec per peer edge; each remote edge still
  owns an independent encoder/RTP sender.
- Prove mixed Native/Web mesh churn without replacing or renegotiating an
  unaffected Native-Native pair.

This specification is narrow enough for a strong first release while leaving clear room for later improvements.
