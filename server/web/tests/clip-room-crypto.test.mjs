import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";
import test from "node:test";

globalThis.crypto ??= webcrypto;
globalThis.btoa ??= (value) => Buffer.from(value, "binary").toString("base64");
globalThis.atob ??= (value) => Buffer.from(value, "base64").toString("binary");

const cryptoModule = await import("../assets/clip-room-crypto.js");
const {
  __test,
  createWebIdentity,
  decodeBase64URL,
  derivePairContext,
  descriptorsEqual,
  encodeBase64URL,
  EncryptedPairChannel,
  openAdmissionRecord,
  openClipV4Invite,
  openRoomValue,
  sealRoomValue,
  validateDescriptor,
} = cryptoModule;

test("deployed invite opener consumes Swift v4 fixture and authenticates path and fragment", async () => {
  const fixtureURL = new URL("../../../Packages/ClipLiveShare/Tests/Fixtures/server-room-v4-invite.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const invite = await openClipV4Invite(fixture.url);
  assert.equal(invite.roomCode, fixture.roomCode);
  assert.equal(invite.roomId, fixture.roomId);
  assert.equal(invite.sessionId, fixture.sessionId);
  assert.equal(invite.admissionCapability, fixture.admissionCapability);
  assert.equal(invite.roomAgreementSecret, fixture.roomAgreementSecret);

  const insecure = new URL(fixture.url); insecure.protocol = "http:";
  await assert.rejects(openClipV4Invite(insecure), /invalid service URL/u);
  const deceptiveLoopback = new URL(fixture.url);
  deceptiveLoopback.protocol = "http:"; deceptiveLoopback.hostname = "localhost.evil.example";
  await assert.rejects(openClipV4Invite(deceptiveLoopback), /invalid service URL/u);
  for (const host of ["localhost:8080", "127.0.0.1:8080", "[::1]:8080"]) {
    const loopback = new URL(fixture.url);
    loopback.protocol = "http:"; loopback.host = host;
    assert.equal((await openClipV4Invite(loopback)).roomId, fixture.roomId);
  }

  const wrongPath = new URL(fixture.url); wrongPath.pathname = "/MESH4BAD";
  await assert.rejects(openClipV4Invite(wrongPath), /authenticated/u);
  const corrupted = new URL(fixture.url);
  const final = corrupted.hash.at(-1);
  corrupted.hash = `${corrupted.hash.slice(0, -1)}${final === "A" ? "B" : "A"}`;
  await assert.rejects(openClipV4Invite(corrupted), /authenticated|invalid|canonical/u);
});

test("web descriptor and signed join canonical bytes match Swift", async () => {
  const fixtureURL = new URL("../../../Packages/ClipLiveShare/Tests/Fixtures/server-room-v4-web-member-descriptor.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  assert.equal(encodeBase64URL(__test.descriptorCanonical(fixture.descriptor)), fixture.descriptorCanonicalBase64URL);
  assert.equal(encodeBase64URL(__test.joinKnockCanonical(fixture.signedJoinKnock.knock)), fixture.joinKnockCanonicalBase64URL);

  const key = await crypto.subtle.importKey(
    "raw",
    decodeBase64URL(fixture.identityPublicKeyBase64URL, 65),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  assert.equal(await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    decodeBase64URL(fixture.signatureBase64URL, 64),
    __test.joinKnockCanonical(fixture.signedJoinKnock.knock),
  ), true);
});

test("descriptor profile pairs are closed and exact", async () => {
  const identity = await createWebIdentity("Browser Viewer");
  assert.equal(validateDescriptor(identity.descriptor).clientKind, "webViewer");
  assert.throws(() => validateDescriptor({ ...identity.descriptor, capabilityProfile: "nativeV1" }), /capability profile/u);
  const { capabilityProfile: _, ...missing } = identity.descriptor;
  assert.throws(() => validateDescriptor(missing), /unexpected fields/u);
  const reordered = Object.fromEntries(Object.entries(identity.descriptor).reverse());
  assert.equal(descriptorsEqual(identity.descriptor, reordered), true);
});

test("room cipher separates domains and rejects tampering", async () => {
  const invite = {
    roomId: encodeBase64URL(new Uint8Array(32).fill(1)),
    sessionId: "browser-room-test",
    roomAgreementSecret: encodeBase64URL(new Uint8Array(32).fill(2)),
  };
  const sealed = await sealRoomValue(invite, "join-knock", { hello: "room" });
  assert.deepEqual(await openRoomValue(invite, "join-knock", sealed), { hello: "room" });
  await assert.rejects(openRoomValue(invite, "admission-record", sealed), /authenticated/u);
  const bytes = decodeBase64URL(sealed); bytes[bytes.length - 1] ^= 1;
  await assert.rejects(openRoomValue(invite, "join-knock", encodeBase64URL(bytes)), /authenticated/u);
});

test("pair crypto agrees across browser peers and rejects replay", async () => {
  const left = await createWebIdentity("Left");
  const right = await createWebIdentity("Right");
  const invite = {
    roomId: encodeBase64URL(new Uint8Array(32).fill(3)),
    sessionId: "pair-session",
  };
  const leftHandle = encodeBase64URL(new Uint8Array(16).fill(4));
  const rightHandle = encodeBase64URL(new Uint8Array(16).fill(5));
  const leftContext = await derivePairContext(invite, leftHandle, left.descriptor.participantID, rightHandle, right.descriptor.participantID);
  const rightContext = await derivePairContext(invite, rightHandle, right.descriptor.participantID, leftHandle, left.descriptor.participantID);
  assert.equal(leftContext.pairId, rightContext.pairId);
  assert.equal(leftContext.initialOfferer, rightContext.initialOfferer);
  const leftChannel = await EncryptedPairChannel.create({ context: leftContext, localIdentity: left, remoteDescriptor: right.descriptor });
  const rightChannel = await EncryptedPairChannel.create({ context: rightContext, localIdentity: right, remoteDescriptor: left.descriptor });
  const envelope = await leftChannel.seal({ type: "offer", epoch: 1, sdp: "v=0\r\n" });
  const routed = { ...envelope, from: leftHandle };
  assert.deepEqual(await rightChannel.open(routed), { type: "offer", epoch: 1, sdp: "v=0\r\n" });
  await assert.rejects(rightChannel.open(routed), /replayed/u);
});

test("browser derives the fixed Swift pair identity and offerer", async () => {
  const context = await derivePairContext(
    {
      roomId: encodeBase64URL(new Uint8Array(32).fill(0x01)),
      sessionId: "v4-session-vector",
    },
    encodeBase64URL(new Uint8Array(16).fill(0x02)),
    encodeBase64URL(new Uint8Array(16).fill(0x21)),
    encodeBase64URL(new Uint8Array(16).fill(0x03)),
    encodeBase64URL(new Uint8Array(16).fill(0x22)),
  );
  assert.equal(context.pairId, "LjIVx8KDdzl4gf3-NxR_0Rs1BVtaVMO0DB89lbPmvHo");
  assert.equal(context.initialOfferer, encodeBase64URL(new Uint8Array(16).fill(0x02)));
});

test("browser opens Swift admission and encrypted pair-signal fixtures", async () => {
  const fixtureURL = new URL("../../../Packages/ClipLiveShare/Tests/Fixtures/server-room-v4-browser-pair.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));
  const invite = {
    roomId: fixture.roomId,
    sessionId: fixture.sessionId,
    roomAgreementSecret: fixture.roomAgreementSecret,
    creatorIdentity: fixture.creatorIdentity,
  };
  const admission = await openAdmissionRecord(invite, fixture.opaqueAdmissionRecord, fixture.browserHandle);
  assert.deepEqual(admission.descriptor, fixture.browserDescriptor);

  const pairPrivateKey = await crypto.subtle.importKey(
    "jwk",
    fixture.browserPairPrivateJWK,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const context = await derivePairContext(
    invite,
    fixture.browserHandle,
    fixture.browserDescriptor.participantID,
    fixture.nativeHandle,
    fixture.nativeDescriptor.participantID,
  );
  assert.equal(context.pairId, fixture.pairId);
  const channel = await EncryptedPairChannel.create({
    context,
    localIdentity: { pairIdentity: { privateKey: pairPrivateKey } },
    remoteDescriptor: fixture.nativeDescriptor,
  });
  assert.deepEqual(await channel.open(fixture.envelope), fixture.expectedPayload);
});

test("restored pair crypto continues its persisted sequences", async () => {
  const left = await createWebIdentity("Left");
  const right = await createWebIdentity("Right");
  const invite = { roomId: encodeBase64URL(new Uint8Array(32).fill(7)), sessionId: "resumed-pair" };
  const leftHandle = encodeBase64URL(new Uint8Array(16).fill(8));
  const rightHandle = encodeBase64URL(new Uint8Array(16).fill(9));
  const context = await derivePairContext(invite, leftHandle, left.descriptor.participantID, rightHandle, right.descriptor.participantID);
  const channel = await EncryptedPairChannel.create({
    context,
    localIdentity: left,
    remoteDescriptor: right.descriptor,
    sequenceState: { outbound: 7, inbound: 11 },
  });
  const envelope = await channel.seal({ type: "renegotiation-request", epoch: 1 });
  assert.equal(envelope.sequence, 8);
  assert.equal(channel.inboundSequence, 11);
});

test("concurrent pair encryption emits a strictly ordered sequence", async () => {
  const left = await createWebIdentity("Left");
  const right = await createWebIdentity("Right");
  const invite = { roomId: encodeBase64URL(new Uint8Array(32).fill(10)), sessionId: "concurrent-pair" };
  const leftHandle = encodeBase64URL(new Uint8Array(16).fill(11));
  const rightHandle = encodeBase64URL(new Uint8Array(16).fill(12));
  const leftContext = await derivePairContext(invite, leftHandle, left.descriptor.participantID, rightHandle, right.descriptor.participantID);
  const rightContext = await derivePairContext(invite, rightHandle, right.descriptor.participantID, leftHandle, left.descriptor.participantID);
  const leftChannel = await EncryptedPairChannel.create({ context: leftContext, localIdentity: left, remoteDescriptor: right.descriptor });
  const rightChannel = await EncryptedPairChannel.create({ context: rightContext, localIdentity: right, remoteDescriptor: left.descriptor });

  // The transport queue normally serializes these calls. This test also proves
  // the channel sequence contract when several encrypted messages are prepared
  // in rapid succession and then opened in wire order.
  const envelopes = [];
  for (let index = 0; index < 8; index += 1) {
    envelopes.push(await leftChannel.seal({ type: "ice-candidate", epoch: 1, candidate: `candidate-${index}`, mediaId: "0", mediaLineIndex: 0 }));
  }
  assert.deepEqual(envelopes.map((entry) => entry.sequence), [1, 2, 3, 4, 5, 6, 7, 8]);
  const payloads = await Promise.all(envelopes.map((entry) => rightChannel.open({ ...entry, from: leftHandle })));
  assert.deepEqual(payloads.map((entry) => entry.candidate), Array.from({ length: 8 }, (_, index) => `candidate-${index}`));
});
