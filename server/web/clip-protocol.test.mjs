import assert from "node:assert/strict";
import test from "node:test";

import {
  canonicalManifest,
  canonicalProtocolFailure,
  canonicalSystemAudioState,
  ClipProtocolError,
  createInnerProtocolFailure,
  createAuthProof,
  createViewerKeyPair,
  decodeBase64URL,
  deriveRouteKeys,
  encodeBase64URL,
  EncryptedRoute,
  MAX_INNER_MESSAGE_BYTES,
  normalizeRoom,
  parseViewerFragment,
  PeerGenerationGuard,
  signalingAAD,
  validateCapabilities,
} from "./clip-protocol.js";
import {
  AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS,
  configureReceiverLatency,
  inboundAudioDiagnostics,
  initialAudioMuted,
  normalizeOpusSystemAudioSDP,
  publicAudioDiagnostics,
} from "./clip-media.js";

test("receiver latency keeps video live without starving audio", () => {
  const audioReceiver = { jitterBufferTarget: 0, playoutDelayHint: 125 };
  assert.equal(configureReceiverLatency(audioReceiver, "audio"), true);
  assert.equal(
    audioReceiver.jitterBufferTarget,
    AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS,
  );
  assert.equal(audioReceiver.playoutDelayHint, 125);

  const videoReceiver = { jitterBufferTarget: 80, playoutDelayHint: 80 };
  assert.equal(configureReceiverLatency(videoReceiver, "video"), true);
  assert.deepEqual(videoReceiver, {
    jitterBufferTarget: 0,
    playoutDelayHint: 0,
  });

  const unsupportedReceiver = {};
  assert.equal(configureReceiverLatency(unsupportedReceiver, "audio"), true);
  assert.deepEqual(unsupportedReceiver, {});
  assert.equal(configureReceiverLatency(null, "audio"), false);
  assert.equal(configureReceiverLatency({}, "data"), false);
});

test("Opus answers explicitly accept stereo music quality", () => {
  const source = [
    "v=0",
    "m=audio 9 UDP/TLS/RTP/SAVPF 111",
    "a=rtpmap:111 opus/48000/2",
    "a=fmtp:111 minptime=10;useinbandfec=1;stereo=0;usedtx=1",
    "m=video 9 UDP/TLS/RTP/SAVPF 96",
    "a=rtpmap:96 VP8/90000",
    "a=fmtp:96 stereo=0",
    "",
  ].join("\r\n");
  const normalized = normalizeOpusSystemAudioSDP(source);
  assert.match(
    normalized,
    /a=fmtp:111 minptime=10;useinbandfec=1;stereo=1;usedtx=0;sprop-stereo=1;maxaveragebitrate=128000\r\n/u,
  );
  assert.match(normalized, /a=fmtp:96 stereo=0\r\n/u);
  assert.equal(normalizeOpusSystemAudioSDP(normalized), normalized);

  const withoutFmtp = [
    "v=0",
    "m=audio 9 UDP/TLS/RTP/SAVPF 109",
    "a=rtpmap:109 opus/48000/2",
  ].join("\n");
  assert.equal(
    normalizeOpusSystemAudioSDP(withoutFmtp),
    [
      "v=0",
      "m=audio 9 UDP/TLS/RTP/SAVPF 109",
      "a=rtpmap:109 opus/48000/2",
      "a=fmtp:109 stereo=1;sprop-stereo=1;maxaveragebitrate=128000;usedtx=0",
    ].join("\n"),
  );
});

test("fresh viewers stay muted until they explicitly opt in", () => {
  assert.equal(initialAudioMuted(null), true);
  assert.equal(initialAudioMuted(undefined), true);
  assert.equal(initialAudioMuted("1"), true);
  assert.equal(initialAudioMuted("0"), false);
  assert.equal(initialAudioMuted("invalid"), true);
});

test("audio diagnostics expose interval loss, concealment and clock repair", () => {
  const first = inboundAudioDiagnostics({
    id: "audio-inbound",
    type: "inbound-rtp",
    kind: "audio",
    timestamp: 1_000,
    trackIdentifier: "opaque-audio",
    codecId: "codec-opus",
    jitter: 0.004,
    audioLevel: 0.25,
    bytesReceived: 8_000,
    packetsReceived: 100,
    packetsLost: 2,
    totalSamplesReceived: 48_000,
    concealedSamples: 480,
    silentConcealedSamples: 240,
    concealmentEvents: 1,
    insertedSamplesForDeceleration: 20,
    removedSamplesForAcceleration: 10,
    jitterBufferDelay: 4,
    jitterBufferEmittedCount: 48_000,
  });
  assert.equal(first.interval.durationMilliseconds, null);

  const second = inboundAudioDiagnostics({
    id: "audio-inbound",
    type: "inbound-rtp",
    kind: "audio",
    timestamp: 2_000,
    trackIdentifier: "opaque-audio",
    codecId: "codec-opus",
    jitter: 0.006,
    audioLevel: 0.5,
    bytesReceived: 16_000,
    packetsReceived: 200,
    packetsLost: 3,
    totalSamplesReceived: 96_000,
    concealedSamples: 960,
    silentConcealedSamples: 480,
    concealmentEvents: 3,
    insertedSamplesForDeceleration: 30,
    removedSamplesForAcceleration: 14,
    jitterBufferDelay: 52,
    jitterBufferEmittedCount: 96_000,
  }, first._baseline);

  assert.equal(second.jitterMilliseconds, 6);
  assert.equal(second.interval.durationMilliseconds, 1_000);
  assert.ok(Math.abs(second.interval.packetLossPercent - 100 / 101) < 1e-9);
  assert.equal(second.interval.concealedSamplePercent, 1);
  assert.equal(second.interval.concealedSamples, 480);
  assert.equal(second.interval.silentConcealedSamples, 240);
  assert.equal(second.interval.concealmentEvents, 2);
  assert.equal(second.interval.insertedSamplesForDeceleration, 10);
  assert.equal(second.interval.removedSamplesForAcceleration, 4);
  assert.equal(second.interval.averageJitterBufferDelayMilliseconds, 1);
  assert.equal("_baseline" in publicAudioDiagnostics(second), false);
  assert.equal(inboundAudioDiagnostics({ type: "inbound-rtp", kind: "video" }), null);
});

test("room and base64url values are canonical and bounded", () => {
  assert.equal(normalizeRoom(" ab-c "), "AB-C");
  assert.throws(() => normalizeRoom("-invalid"), ClipProtocolError);

  const bytes = crypto.getRandomValues(new Uint8Array(32));
  assert.deepEqual(decodeBase64URL(encodeBase64URL(bytes), 32), bytes);
  assert.throws(() => decodeBase64URL("***"), ClipProtocolError);
  assert.throws(() => decodeBase64URL(""), ClipProtocolError);
  assert.throws(() => decodeBase64URL("AB"), ClipProtocolError);
  assert.equal(MAX_INNER_MESSAGE_BYTES, 196_400);
});

test("viewer fragments contain exactly one version and one canonical key", () => {
  const publicKey = new Uint8Array(65);
  publicKey[0] = 0x04;
  const encodedKey = encodeBase64URL(publicKey);
  assert.deepEqual(
    parseViewerFragment(`#v=1&key=${encodedKey}`).roomPublicKey,
    publicKey,
  );
  assert.throws(
    () => parseViewerFragment(`#v=1&key=${encodedKey}&extra=value`),
    ClipProtocolError,
  );
  assert.throws(
    () => parseViewerFragment(`#v=1&v=1&key=${encodedKey}`),
    ClipProtocolError,
  );
  assert.throws(
    () => parseViewerFragment(`#v=1&key=%30${encodedKey.slice(1)}`),
    ClipProtocolError,
  );
});

test("server capabilities preserve only bounded v1 routes and ICE configuration", () => {
  const capabilities = {
    protocol: "clip-live-share",
    versions: [1],
    serverVersion: "fixture",
    viewerPathTemplate: "/{room}",
    hostWebSocketPathTemplate: "/api/v1/rooms/{room}/host",
    viewerWebSocketPathTemplate: "/api/v1/rooms/{room}/viewer",
    iceServers: [{ urls: ["stun:stun.example.test:3478"] }],
    limits: {
      maximumMessageBytes: 262_144,
      maximumPendingViewersPerRoom: 8,
    },
  };
  assert.equal(
    validateCapabilities(capabilities).viewerWebSocketPathTemplate,
    "/api/v1/rooms/{room}/viewer",
  );
  assert.throws(
    () => validateCapabilities({ ...capabilities, versions: [1, 1] }),
    ClipProtocolError,
  );
  assert.throws(
    () => validateCapabilities({ ...capabilities, iceServers: [{ urls: ["https://bad.test"] }] }),
    ClipProtocolError,
  );
  assert.throws(
    () => validateCapabilities({ ...capabilities, viewerWebSocketPathTemplate: "/{room}/../host" }),
    ClipProtocolError,
  );
});

test("access-code proof matches the Swift interoperability vector", async () => {
  const proof = await createAuthProof({
    accessCode: " abcd ",
    challenge: encodeBase64URL(new Uint8Array(32)),
    sessionId: "fixture-session",
  });
  assert.equal(proof, "GGxWyuqbYQE6wenANE1t82NMizAF8LnO51AUwwOLLR0");
});

test("protocol failures use the shared ASCII and UTF-8 bounds", () => {
  assert.deepEqual(canonicalProtocolFailure({ code: "auth-failed", message: "Denied" }), {
    code: "auth-failed",
    message: "Denied",
  });
  assert.throws(
    () => canonicalProtocolFailure({ code: "bad code", message: "Denied" }),
    ClipProtocolError,
  );
  assert.throws(
    () => canonicalProtocolFailure({ code: "failure", message: "😀".repeat(65) }),
    ClipProtocolError,
  );
});

test("authoritative system audio requires a boolean enabled state", () => {
  assert.equal(canonicalSystemAudioState({ enabled: true }), true);
  assert.equal(canonicalSystemAudioState({ enabled: false }), false);
  assert.throws(() => canonicalSystemAudioState({ enabled: "yes" }), ClipProtocolError);
  assert.throws(() => canonicalSystemAudioState({}), ClipProtocolError);
});

test("renegotiation failures are bounded typed control messages", () => {
  assert.deepEqual(
    createInnerProtocolFailure(
      "fixture-session",
      "renegotiation-failed",
      "The browser could not apply Clip's WebRTC update.",
    ),
    {
      type: "error",
      version: 1,
      sessionId: "fixture-session",
      code: "renegotiation-failed",
      message: "The browser could not apply Clip's WebRTC update.",
    },
  );
  assert.throws(
    () => createInnerProtocolFailure("fixture-session", "bad code", "Denied"),
    ClipProtocolError,
  );
  assert.throws(
    () => createInnerProtocolFailure("fixture-session", "failure", "😀".repeat(65)),
    ClipProtocolError,
  );
});

test("peer generations reject stale asynchronous completions", () => {
  const guard = new PeerGenerationGuard();
  const first = {};
  const firstGeneration = guard.replace(first);
  assert.equal(guard.isCurrent(first, firstGeneration), true);

  const second = {};
  const secondGeneration = guard.replace(second);
  assert.equal(guard.isCurrent(first, firstGeneration), false);
  assert.equal(guard.isCurrent(second, secondGeneration), true);

  guard.clear();
  assert.equal(guard.isCurrent(second, secondGeneration), false);
});

test("P-256, HKDF and AES-GCM accept the host-to-viewer direction", async () => {
  const host = await createViewerKeyPair();
  const viewer = await createViewerKeyPair();
  const routeId = encodeBase64URL(new Uint8Array(16).fill(7));
  const viewerKeys = await deriveRouteKeys({
    privateKey: viewer.privateKey,
    roomPublicKey: host.publicKey,
    room: "ABC",
    routeId,
  });
  const hostKeys = await deriveRouteKeys({
    privateKey: host.privateKey,
    roomPublicKey: viewer.publicKey,
    room: "ABC",
    routeId,
  });
  const route = new EncryptedRoute({ room: "ABC", routeId, ...viewerKeys });
  const nonce = new Uint8Array(12).fill(9);
  const plaintext = new TextEncoder().encode(JSON.stringify({
    type: "fixture",
    version: 1,
    sessionId: "session",
  }));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: nonce,
      additionalData: signalingAAD("ABC", routeId, "host-to-viewer", 1),
      tagLength: 128,
    },
    hostKeys.inboundKey,
    plaintext,
  );
  const envelope = {
    type: "relay",
    routeId,
    sequence: 1,
    nonce: encodeBase64URL(nonce),
    ciphertext: encodeBase64URL(ciphertext),
  };

  assert.equal((await route.open(envelope)).type, "fixture");
  await assert.rejects(() => route.open(envelope), (error) => {
    assert.equal(error.code, "invalid-sequence");
    return true;
  });

  const outbound = await route.seal({ type: "viewer-fixture", version: 1, sessionId: "session" });
  assert.equal("routeId" in outbound, false, "viewer relay routing must remain implicit");
});

test("WebCrypto decrypts the deterministic Swift host-to-viewer vector", async () => {
  const viewerPublicKey = decodeBase64URL(
    "BFUPRxAD89-Xw99QaseX9nIfsaH7e49vg9IkSYplyI4kE2CT1wEuUJpzcVy9CwCjzA_0tcAbP_oZarH7MnA2uOY",
    65,
  );
  const privateKey = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      x: encodeBase64URL(viewerPublicKey.slice(1, 33)),
      y: encodeBase64URL(viewerPublicKey.slice(33, 65)),
      d: encodeBase64URL(new Uint8Array(32).fill(2)),
      ext: false,
      key_ops: ["deriveBits"],
    },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const routeId = "AAECAwQFBgcICQoLDA0ODw";
  const route = new EncryptedRoute({
    room: "CALM-OTTER-042",
    routeId,
    ...(await deriveRouteKeys({
      privateKey,
      roomPublicKey: decodeBase64URL(
        "BG_wO5SSQc4drdQ1GeaWDgqFtBppoFwygQOqK84VlMoWPE91OlW_AdxT9sCwx-7ni0DG_30lqW4igrmJzvccFEo",
        65,
      ),
      room: "CALM-OTTER-042",
      routeId,
    })),
  });
  const message = await route.open({
    type: "relay",
    routeId,
    sequence: 1,
    nonce: encodeBase64URL(Uint8Array.from({ length: 12 }, (_, index) => 0xa0 + index)),
    ciphertext:
      "9JVD38RQnClfiXquPZMiWfXvNU-sE4fTg07AgPczQd7ZMq7Q-uN75i0yciFsuYhMxaZt2KQqkMU1UXxBzLmRL-NFL2uNspEeZigvLFAFcNwh56BF2l_px6Ncs26U44c",
  });
  assert.deepEqual(message, {
    allowed: true,
    sessionId: "fixture-session",
    type: "auth-result",
    version: 1,
  });
});

test("manifest identity is opaque, authoritative and strict", () => {
  const manifest = canonicalManifest({
    streams: [
      {
        id: "opaque-b",
        mediaTrackId: "browser-b",
        active: true,
        focused: false,
        appName: "Browser",
        windowName: "Docs",
        width: 800,
        height: 600,
        order: 2,
      },
      {
        id: "opaque-a",
        mediaTrackId: "browser-a",
        active: true,
        focused: true,
        appName: "Editor",
        windowName: "Code",
        width: 1_280,
        height: 720,
        order: 1,
      },
    ],
  });
  assert.deepEqual(manifest.map((entry) => entry.id), ["opaque-a", "opaque-b"]);
  assert.throws(
    () => canonicalManifest({
      streams: [
        {
          ...manifest[0],
          id: "opaque-a",
          mediaTrackId: "same-track",
        },
        {
          ...manifest[1],
          id: "opaque-b",
          mediaTrackId: "same-track",
        },
      ],
    }),
    ClipProtocolError,
  );
  assert.throws(
    () => canonicalManifest({
      streams: [{
        ...manifest[0],
        appName: "😀".repeat(129),
      }],
    }),
    ClipProtocolError,
    "text limits are UTF-8 bytes, not JavaScript code units",
  );
  assert.throws(
    () => canonicalManifest({
      streams: [
        { ...manifest[0], id: "first", mediaTrackId: "first-track", order: 1 },
        { ...manifest[1], id: "second", mediaTrackId: "second-track", order: 1 },
      ],
    }),
    ClipProtocolError,
    "manifest order values must be unique",
  );
  assert.throws(
    () => canonicalManifest({ streams: [{ ...manifest[0], id: undefined, streamId: "legacy" }] }),
    ClipProtocolError,
    "legacy track aliases must not replace opaque v1 identity",
  );
  assert.throws(
    () => canonicalManifest({ streams: [{ ...manifest[0], active: false, focused: true }] }),
    ClipProtocolError,
    "an inactive stream cannot be focused",
  );
});
