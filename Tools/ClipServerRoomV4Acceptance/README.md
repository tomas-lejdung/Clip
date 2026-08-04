# Clip server-room v4 acceptance

This command-line harness exercises the real Go room service through Clip's
real Swift HTTP and WebSocket transports. It does not launch the app, request
screen-capture permission, create media, or drive the pointer.

Run it from the repository root:

```bash
./scripts/run-server-room-v4-acceptance.sh
```

The wrapper builds an isolated local server, waits for its health endpoint,
runs four real URLSession clients, and always terminates the server afterward.
It fails unless it proves all of the following:

- The same byte-stable invite admits three successive candidates.
- Every connected client receives the same authoritative 2-, 3-, and
  4-member roster.
- Those rosters produce exactly 1, 3, and 6 unordered direct pairs.
- Opaque, authenticated pair signals traverse all 12 directions in a
  four-member mesh and decrypt to their original payloads.
- A consumed-but-unsent sequence does not wedge a pair; sequence 2 succeeds
  while duplicate/replay rejection remains covered by package/server tests.
- Adding members never closes or reconnects existing participant sockets.
- A noncreator leave removes only its three incident pairs.
- That member can rejoin from the exact same invite with the same persistent
  signing identity and a fresh room incarnation; all six pairs are restored,
  all six new pair directions carry authenticated encrypted signaling, and
  the three retained sockets never reconnect.
- Explicit creator leave delivers `room-ended` to every remaining member and
  removes the room.
- A completed signed friendship publishes the active creator's encrypted
  canonical invite through the real HTTP presence endpoint; the idle friend
  can fetch and verify it repeatedly, while an ordinary participant publishes
  no room presence.
- HTTP URLs, headers, bodies, and client-to-server WebSocket envelopes contain
  no invite fragment, admission/room secret, session binding, persistent
  identity, participant/device name, or plaintext SDP.

The final JSON object is intentionally stable and suitable for CI evidence.
Random room, identity, and encryption material is generated for each run and
is never written to disk.
