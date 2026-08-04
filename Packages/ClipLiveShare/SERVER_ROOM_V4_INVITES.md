# Room v4 Invites

Clip uses one canonical invitation for both the native app and the receive-only
web participant:

```text
https://ROOM-SERVICE/ROOMCODE#v=4&key=SEALED-PAYLOAD&join=ADMISSION-CAPABILITY
```

`ROOMCODE` is an eight-character, uppercase presentation code. It is not the
room service's API identifier and grants no access. The encrypted `key` payload
contains the opaque 256-bit API room ID, session binding, creator identity,
room agreement secret, and a copy of the admission capability. `join` derives
the payload-encryption key and authorizes a candidate to knock.

The browser does not send a URL fragment in HTTP requests, so an honest room
service receives neither `key` nor `join`. The web viewer nevertheless treats
the same-origin JavaScript served by Clip's room service as part of the trusted
client: JavaScript can read the fragment and could exfiltrate it if the origin
were compromised. The viewer therefore uses only repository-owned assets and
loads no third-party scripts, fonts, styles, analytics, or CDNs.

The browser requires HTTPS for every non-loopback invite. Plain HTTP is
accepted only for the exact local-development hosts `localhost`, `127.0.0.1`,
and `[::1]`; lookalike and subdomain names are not loopback exceptions.

The sealed payload uses AES-256-GCM. Its key is HKDF-SHA256 over `join`, and its
authenticated data binds protocol v4 and the exact `/ROOMCODE` path. Changing
the visible room code therefore invalidates the ciphertext instead of allowing
one private room to be relabeled.

An invite is byte-stable for the life of that invite. Copying it, admitting or
removing participants, reconnecting, or applying a roster never changes it.
Only the explicit **New Invite** operation rotates `join` and reseals `key`;
the human room code and opaque API room remain the same.

There is deliberately no v1/v2/v3 URL compatibility in this clean-slate
protocol. Parsers require the exact field order and reject queries, unknown
fields, noncanonical base64url, percent-encoded room codes, and additional path
components.

The browser reference parser lives in
`Web/clip-server-room-v4-invite.mjs`, and the deployed viewer uses the matching
WebCrypto implementation in `server/web/assets/clip-room-crypto.js`. Swift and
JavaScript share the fixed cross-language fixture in
`Tests/Fixtures/server-room-v4-invite.json`.

Every parser enforces the same service-transport boundary: remote room services
must use HTTPS. Plain HTTP is accepted only for development on the exact
loopback hosts `localhost`, `127.0.0.1`, and `[::1]`; localhost suffixes and
lookalike hosts are rejected.

After decryption, Native and Web enter the same authoritative room roster and
use the same encrypted pair-signaling contract. A signed member descriptor
declares the closed client profile (`nativeApp/nativeV1` or
`webViewer/webViewerV1`) for capability presentation; it does not create a
second admission or signaling protocol.

## Saved-friend presence

Each committed friendship exchanges two independent, directional presence
locators over the already authenticated end-to-end DataChannel. A locator is a
random 256-bit routing ID plus a separate 256-bit presence secret. One locator
is used for Alice to publish only to Bob, and the other for Bob to publish only
to Alice. Clip must never reuse one presence locator for several friends.

While Alice has an active room, she periodically encrypts that room's current
canonical v4 invite for Bob's locator and publishes the opaque record to:

```text
PUT /api/native/v4/friends/ROUTING_ID/presence
```

Bob polls the same path with `GET`, decrypts the record with the friend-only
secret, verifies Alice's persistent identity signature, verifies that Bob is
the intended recipient, and only then exposes the invite as joinable. Presence
records expire after at most five minutes. Revisions increase monotonically;
the server retains a short revision tombstone after expiry so a delayed older
record cannot become current again.

The room service stores only the random routing ID, revision, expiry, and
ciphertext. It never receives either friend's identity or name, the presence
secret, or the room invite in plaintext. It can still observe ordinary network
metadata such as source IP, request timing, record size, and repeated access to
the same opaque routing ID. A friend who knows a locator can suppress that
locator's presence by overwriting ciphertext, but cannot forge a valid room
announcement because each decrypted publication must carry the expected
persistent identity signature.

Refreshing presence does not rotate or otherwise mutate the room invite.
Only the room owner's explicit **New Invite** action changes the invite that is
encrypted into later presence publications.
