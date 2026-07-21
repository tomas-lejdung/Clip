# Clip native Friends and viewer progress board

Branch: `codex/native-friends-viewer`

Started: 2026-07-21

Product contract: [spec.md](../spec.md#native-viewer-and-friends)

Existing architecture: [live-share-architecture.md](live-share-architecture.md)

Existing browser protocol: [clip-live-share-protocol-v1.md](clip-live-share-protocol-v1.md)

## Status model

- `PENDING` — accepted scope with no implementation evidence yet.
- `IN_PROGRESS` — production implementation or its named deterministic gate is
  not yet complete.
- `DONE` — production wiring and deterministic unattended evidence are complete;
  any real-device gate is called out separately rather than implied.
- `EXTERNAL_GATE` — implementation and deterministic evidence are complete, but
  acceptance still needs independent GUI processes, privacy-authorized capture,
  physical displays, or a controlled remote network.

## Feature board

| ID | Lane | Status | Evidence-based outcome |
| --- | --- | --- | --- |
| NFV-00 | Product and threat model | `DONE` | Preparation/Start, one complete invite, persistent device identities, server-blind labels and trust, explicit per-connection host approval, bounded crash recovery, browser fallback and native multi-window behavior are fixed in the product specification. |
| NFV-01 | Native receiver | `DONE` | The Swift 6 receiver answers, exchanges ICE, handles renegotiation, binds early or late tracks to authoritative manifests, reports transport state, emits one audio track, and tears down deterministically. |
| NFV-02 | Viewer control reducer | `DONE` | Versioned manifests and native lifecycle revisions reduce stream generations, focus, geometry, cursor, audio, sharing and close events into race-safe state without resurrecting stale v1 sources. |
| NFV-03 | Native remote windows | `DONE` | Each of four manual sources owns an independent macOS window; Auto Share reuses one stable window. Receiver title chrome and the redundant source chip are visually removed in favor of a friend-colored outer frame and matching custom draggable header. Header controls are translucent until hover. Hide, reopen, Show All, remove, reconnect and authoritative reconciliation have deterministic coverage, and host focus never raises or moves local windows. |
| NFV-04 | Native resolution | `DONE` | Authoritative source logical dimensions remain stable across Retina and non-Retina receivers. Fit preserves aspect ratio without default upscaling; Native 100% preserves logical size, crops oversized content, follows the focused remote cursor without revealing blanks, reports zoom and can reset the window to actual logical size. Backing-scale changes and transient adaptation geometry do not corrupt the source size. |
| NFV-05 | Remote identity and cursor | `DONE` | The thick friend-colored frame and matching header stay outside video, focus only brightens the identity treatment, reconnect turns it gray, and title contrast adapts to the identity color. The host captures its cursor only into the focused source; native state rejects stale or wrong-source cursor routing, and Native 100% panning follows only that accepted cursor. |
| NFV-06 | Viewer audio and controls | `DONE` | One aggregate Opus receiver is accepted and played once per session across renegotiation; mute, volume, visible/hidden sources, P2P/TURN state, statistics, Show All and Leave are production-wired. Host focus changes only presentation state and never rearrange local windows. |
| NFV-07 | Persistent device identity | `DONE` | A Keychain-backed P-256 signing identity produces a canonical fingerprint and signs fresh session descriptors. Private key material never reaches the rendezvous service or ordinary friend persistence, and reset creates a new device identity. |
| NFV-08 | Friends persistence | `DONE` | Editable local names, pinned public identities, endpoint, opaque rendezvous capability, trust state, device name, block, remove and identity reset use atomic local snapshots without session passwords or private identity material. |
| NFV-09 | Add Friend and recovery | `DONE` | Pairing is authenticated inside an active peer and uses signed request, acceptance, requester ACK and host commit receipt. The requester remains **Finishing setup** until receipt validation. Exact evidence is retried idempotently through a 16-entry, seven-day local journal so one-sided crashes can converge without claiming cross-device atomicity. |
| NFV-10 | Friend presence | `DONE` | The Go service exposes bounded opaque presence leases, signed descriptors and temporary routes, supports preparing/active transitions, retains no friend graph or offline queue, and cannot authorize a viewer. Pre-Start browser/native-v1 routes wait only within a bounded placeholder and create no peer or approval prompt. |
| NFV-11 | Friend admission | `DONE` | Selecting a Live friend verifies the signed fresh descriptor, proves the saved viewer identity, asks the host to Allow or Deny that route, rechecks trust after asynchronous approval, and fails closed on expiry, replay, mismatch, removal or block. |
| NFV-12 | Preparation and Start UI | `DONE` | Live Share prepares a fresh room without capture, presence or approval. Copy Invite, Join an Invite, New Room, optional access code, Live Friends and Start Sharing precede Sources, Settings, Viewers and Statistics; zero-source Start has an explicit waiting state. |
| NFV-13 | Native invite join | `DONE` | Clip accepts a complete invite and joins natively without browser JavaScript. The invite's endpoint, room and ephemeral P-256 key are one session's authentication context and are never treated as persistent identity. The 1.3.1 regression gate delivers the host's signed native descriptor after the P2P DataChannel opens through both invite and saved-Friend viewer sessions. |
| NFV-14 | Browser compatibility | `EXTERNAL_GATE` | Browser protocol-v1 and native receiver implementations remain production-wired to independent host peers, and each path has deterministic coverage. A simultaneous real WebKit plus native Clip session has not yet been accepted, so mixed-client behavior is not claimed complete. |
| NFV-15 | Role and lifecycle integration | `DONE` | Recording, hosting and viewing are mutually exclusive. Unstarted host preparation is awaited before installing a viewer, role tokens reject late callbacks, and stop/quit paths tear down viewer windows, audio, peers, routes and host UI. |
| NFV-16 | End-to-end friendship journey | `EXTERNAL_GATE` | Deterministic protocol composition proves pairing, ACK/receipt, a fresh room/key, identity proof, approval, removal and rejection; loopback peers prove media/control survive an in-process signaling handoff. Two independently launched signed Clip GUI processes, crash/relaunch recovery and killing the actual signaling-server process remain external gates. |
| NFV-17 | Multi-window journey | `EXTERNAL_GATE` | Deterministic receiver and window tests cover four source bindings, add/update/hide/show/remove, source-logical Fit and cropped Native 100% sizing, custom chrome, onscreen clamping, focus without key theft, focused-source cursor capture, stale routing rejection, cursor-follow panning, reconnect and audio once. Real ScreenCaptureKit sources, Fullscreen replacement, Retina/multi-display movement and manual window interaction remain external gates. |
| NFV-18 | Signed review build | `DONE` | The full local acceptance, hosted-app and strict Swift 6 source/link/test-source gates pass. The repo Release build is sealed with the persistent Apple Development identity for Team `FJ2BS65H3F`, hardened runtime and the sandbox entitlements; `/Applications/Clip.app` remains untouched. |

## Deterministic evidence boundary

Repository tests compose the signed native-v2 friendship messages, persistent
journal, fresh-room identity proof, rejection after removal, rendezvous limits,
viewer state reducer, four-track WebRTC receiver, stereo-audio-once behavior,
control after signaling handoff, native window reconciliation, source-logical
sizing, Fit and cropped Native 100% geometry, custom chrome, border state,
focused-source cursor capture, stale cursor rejection, cursor-follow panning,
deployment ICE/TURN configuration and application role gate. These are
pointer-free and do not need Screen Recording permission.

The two receivers used by the multi-peer loopback test both exercise the native
receiver implementation. Naming one fixture as browser-compatible does not make
it an embedded WebKit viewer. Ending the test's signaling bridge proves that an
established peer and DataChannel continue without that bridge; it does not prove
behavior when the real Go server process is killed. Those distinctions remain
explicit external acceptance items.

## Remaining external acceptance

- Launch two separately signed Clip GUI processes and complete invite pairing,
  Add Friend, fresh-room discovery, per-connection approval, disconnect,
  crash/relaunch recovery, removal and subsequent rejection.
- Run a native Clip viewer and the embedded WebKit viewer simultaneously against
  one real host and verify independent admission, media and teardown.
- Kill and restart the actual Go signaling service only after peers are fully
  established; verify video, the single audio track and control stay live, then
  verify the documented reconnect/new-admission behavior.
- Share one through four real ScreenCaptureKit windows and Fullscreen; exercise
  add/remove/resize, Auto Share, zero-source waiting and source replacement.
- Move and resize remote windows across Retina and non-Retina displays and
  Spaces; verify source-logical sizing, Fit and Native 100% crop/pan behavior,
  zoom reset, the external custom frame/header, translucent-to-opaque control
  hover, focused-window-only cursor presentation, local key-window ownership
  and last-window close choice.
- Exercise direct remote ICE and configured TURN relay on controlled networks,
  and confirm the viewer reports the selected P2P or relay path.

## Non-goals for this milestone

- Remote keyboard or pointer control.
- Simultaneous hosting and viewing in one Clip process.
- Multiple concurrent friend sessions in one Clip process.
- Server-owned accounts, names, friend graphs, passwords, viewer counts or
  history.
- Replacing WebRTC with a custom media transport.
- Removing the browser viewer fallback.

## Friendship commit recovery boundary

Friendship is not an atomic write across two Macs. Clip first persists the
requester's hidden pending contact, signed host acceptance and exact signed
acknowledgement. The host then persists its trusted contact and the same signed
evidence before creating and persisting its signed commit receipt. Only after
that receipt validates does the requester atomically promote its contact and
remove its local pending evidence.

One-sided crashes can converge by replaying the exact signed acknowledgement or
receipt during a later P2P session authenticated by the same persistent device
identities. The old room/session is evidence context, not a live transport
dependency. Journals are capped at 16 entries and evidence expires after seven
days. Completion removes requester evidence; decline, local removal, blocking,
identity reset, expiry and deterministic capacity eviction also clear the
applicable entries. Recovery is therefore bounded and conditional on retained
valid evidence and reconnecting identities. No server-side trust state or
cross-device atomicity is claimed.
