const VERSION = 4;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

export class ClipWebProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ClipWebProtocolError";
    this.code = code;
  }
}

export function encodeBase64URL(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export function decodeBase64URL(value, expectedLength = null) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value) || value.length % 4 === 1) {
    throw new ClipWebProtocolError("invalid-base64url", "A private room value is invalid.");
  }
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  let binary;
  try {
    binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
  } catch {
    throw new ClipWebProtocolError("invalid-base64url", "A private room value is invalid.");
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (encodeBase64URL(bytes) !== value || (expectedLength !== null && bytes.length !== expectedLength)) {
    throw new ClipWebProtocolError("invalid-base64url", "A private room value is not canonical.");
  }
  return bytes;
}

function encodeBase64Data(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function decodeBase64Data(value, expectedLength = null) {
  if (typeof value !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)) {
    throw new ClipWebProtocolError("invalid-data", "A protected binary field is invalid.");
  }
  let bytes;
  try { bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0)); } catch {
    throw new ClipWebProtocolError("invalid-data", "A protected binary field is invalid.");
  }
  if (encodeBase64Data(bytes) !== value || (expectedLength !== null && bytes.length !== expectedLength)) {
    throw new ClipWebProtocolError("invalid-data", "A protected binary field is not canonical.");
  }
  return bytes;
}

export function concatenate(...values) {
  const arrays = values.map((value) => value instanceof Uint8Array ? value : new Uint8Array(value));
  const output = new Uint8Array(arrays.reduce((total, value) => total + value.length, 0));
  let offset = 0;
  for (const value of arrays) {
    output.set(value, offset);
    offset += value.length;
  }
  return output;
}

function uint32(value) {
  const output = new Uint8Array(4);
  new DataView(output.buffer).setUint32(0, value, false);
  return output;
}

function uint64(value) {
  const output = new Uint8Array(8);
  new DataView(output.buffer).setBigUint64(0, BigInt(value), false);
  return output;
}

export class CanonicalEncoder {
  constructor(domain) {
    this.parts = [];
    this.appendString(domain);
    this.appendUInt64(VERSION);
  }

  appendBytes(value) {
    const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
    if (bytes.length > 0xffffffff) throw new RangeError("Canonical field is too large");
    this.parts.push(uint32(bytes.length), bytes);
    return this;
  }

  appendString(value) { return this.appendBytes(textEncoder.encode(value)); }
  appendBool(value) { this.parts.push(Uint8Array.of(value ? 1 : 0)); return this; }
  appendUInt32(value) { this.parts.push(uint32(value)); return this; }
  appendUInt64(value) { this.parts.push(uint64(value)); return this; }
  data() { return concatenate(...this.parts); }
}

function randomBytes(count) {
  return crypto.getRandomValues(new Uint8Array(count));
}

async function sha256(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", value));
}

async function importSigningPublic(raw) {
  return crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
}

async function importAgreementPublic(raw) {
  return crypto.subtle.importKey("raw", raw, { name: "ECDH", namedCurve: "P-256" }, false, []);
}

async function signRaw(privateKey, data) {
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    data,
  ));
  if (signature.length !== 64) throw new ClipWebProtocolError("signature-failed", "The browser generated an invalid identity signature.");
  return signature;
}

async function verifyRaw(publicKey, signature, data) {
  return crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signature,
    data,
  );
}

export async function openClipV4Invite(value) {
  const url = value instanceof URL ? new URL(value.href) : new URL(value);
  if (!isTrustedViewerTransport(url) || url.username || url.password || url.search) {
    throw new ClipWebProtocolError("invalid-invite", "This Clip invitation has an invalid service URL.");
  }
  const path = /^\/([A-Z0-9]{8})$/u.exec(url.pathname);
  if (!path) throw new ClipWebProtocolError("invalid-invite", "This Clip invitation has an invalid room code.");
  const fields = url.hash.slice(1).split("&");
  if (fields.length !== 3 || fields[0] !== "v=4" || !fields[1].startsWith("key=") || !fields[2].startsWith("join=")) {
    throw new ClipWebProtocolError("invalid-invite", "This Clip invitation is incomplete.");
  }
  const roomCode = path[1];
  const sealed = decodeBase64URL(fields[1].slice(4));
  const admissionCapability = decodeBase64URL(fields[2].slice(5), 32);
  if (sealed.length <= 28 || sealed.length > 8192) throw new ClipWebProtocolError("invalid-invite", "This Clip invitation is invalid.");
  const input = await crypto.subtle.importKey("raw", admissionCapability, "HKDF", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: textEncoder.encode("clip-live-share-server-room-v4/invite/salt"),
      info: textEncoder.encode("clip-live-share-server-room-v4/invite/payload"),
    },
    input,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
  const aad = new CanonicalEncoder("clip-live-share-server-room-v4/invite")
    .appendString(`/${roomCode}`)
    .data();
  let plaintext;
  try {
    plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: sealed.slice(0, 12), additionalData: aad, tagLength: 128 },
      key,
      sealed.slice(12),
    );
  } catch {
    throw new ClipWebProtocolError("invalid-invite", "This Clip invitation could not be authenticated.");
  }
  const payload = strictJSON(plaintext, [
    "admissionCapability", "creatorIdentity", "roomAgreementSecret", "roomId", "sessionId", "version",
  ]);
  if (payload.version !== VERSION || typeof payload.sessionId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(payload.sessionId)) {
    throw new ClipWebProtocolError("invalid-invite", "This Clip invitation uses invalid room material.");
  }
  decodeBase64URL(payload.roomId, 32);
  decodeBase64URL(payload.creatorIdentity, 65);
  decodeBase64URL(payload.roomAgreementSecret, 32);
  if (!equalBytes(decodeBase64URL(payload.admissionCapability, 32), admissionCapability)) {
    throw new ClipWebProtocolError("invalid-invite", "This Clip invitation has mismatched admission material.");
  }
  await importSigningPublic(decodeBase64URL(payload.creatorIdentity, 65));
  return Object.freeze({
    version: VERSION,
    roomCode,
    serviceEndpoint: url.origin,
    roomId: payload.roomId,
    sessionId: payload.sessionId,
    creatorIdentity: payload.creatorIdentity,
    roomAgreementSecret: payload.roomAgreementSecret,
    admissionCapability: payload.admissionCapability,
  });
}

function isTrustedViewerTransport(url) {
  if (url.protocol === "https:") return true;
  if (url.protocol !== "http:") return false;
  // WebCrypto treats loopback as a trustworthy development context. Plain HTTP
  // anywhere else would let an on-path attacker replace the viewer JavaScript
  // and read the otherwise server-invisible URL fragment.
  return url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
}

function strictJSON(value, exactKeys = null) {
  let object;
  try { object = JSON.parse(textDecoder.decode(value)); } catch {
    throw new ClipWebProtocolError("invalid-json", "A protected room message is invalid.");
  }
  if (!object || Array.isArray(object) || typeof object !== "object") {
    throw new ClipWebProtocolError("invalid-json", "A protected room message is invalid.");
  }
  if (exactKeys) requireExactKeys(object, exactKeys);
  return object;
}

function requireExactKeys(object, expected) {
  const keys = Object.keys(object).sort();
  const wanted = [...expected].sort();
  if (keys.length !== wanted.length || keys.some((key, index) => key !== wanted[index])) {
    throw new ClipWebProtocolError("invalid-shape", "A protected room message has unexpected fields.");
  }
}

function equalBytes(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

function descriptorCanonical(descriptor) {
  validateDescriptor(descriptor);
  return new CanonicalEncoder("clip-live-share-server-room-v4/member-descriptor")
    .appendBytes(decodeBase64URL(descriptor.participantID, 16))
    .appendBytes(decodeBase64URL(descriptor.identity, 65))
    .appendBytes(decodeBase64URL(descriptor.pairSignalingPublicKey, 65))
    .appendString(descriptor.displayName)
    .appendString(descriptor.deviceName)
    .appendString(descriptor.clientKind)
    .appendString(descriptor.capabilityProfile)
    .data();
}

export function descriptorsEqual(left, right) {
  try {
    validateDescriptor(left);
    validateDescriptor(right);
    return [
      "participantID", "identity", "pairSignalingPublicKey", "displayName",
      "deviceName", "clientKind", "capabilityProfile",
    ].every((field) => left[field] === right[field]);
  }
  catch { return false; }
}

export function validateDescriptor(descriptor) {
  requireExactKeys(descriptor, [
    "participantID", "identity", "pairSignalingPublicKey", "displayName", "deviceName", "clientKind", "capabilityProfile",
  ]);
  decodeBase64URL(descriptor.participantID, 16);
  decodeBase64URL(descriptor.identity, 65);
  decodeBase64URL(descriptor.pairSignalingPublicKey, 65);
  for (const field of ["displayName", "deviceName"]) {
    if (typeof descriptor[field] !== "string" || textEncoder.encode(descriptor[field]).length < 1 || textEncoder.encode(descriptor[field]).length > 160) {
      throw new ClipWebProtocolError("invalid-descriptor", "A participant name is invalid.");
    }
  }
  const validProfile =
    (descriptor.clientKind === "nativeApp" && descriptor.capabilityProfile === "nativeV1") ||
    (descriptor.clientKind === "webViewer" && descriptor.capabilityProfile === "webViewerV1");
  if (!validProfile) throw new ClipWebProtocolError("invalid-descriptor", "A participant capability profile is invalid.");
  return descriptor;
}

export async function createWebIdentity(displayName = "Web Viewer") {
  const [identity, pairIdentity] = await Promise.all([
    crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]),
    crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]),
  ]);
  const identityPublic = new Uint8Array(await crypto.subtle.exportKey("raw", identity.publicKey));
  const pairPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pairIdentity.publicKey));
  const participantID = randomBytes(16);
  const descriptor = {
    participantID: encodeBase64URL(participantID),
    identity: encodeBase64URL(identityPublic),
    pairSignalingPublicKey: encodeBase64URL(pairPublic),
    displayName: String(displayName).slice(0, 80) || "Web Viewer",
    deviceName: "Browser",
    clientKind: "webViewer",
    capabilityProfile: "webViewerV1",
  };
  validateDescriptor(descriptor);
  return { identity, pairIdentity, participantID, descriptor };
}

export async function exportWebIdentity(identity) {
  return {
    identityPrivateJWK: await crypto.subtle.exportKey("jwk", identity.identity.privateKey),
    pairPrivateJWK: await crypto.subtle.exportKey("jwk", identity.pairIdentity.privateKey),
    participantID: encodeBase64URL(identity.participantID),
    descriptor: identity.descriptor,
  };
}

export async function importWebIdentity(value) {
  if (!value || typeof value !== "object") throw new ClipWebProtocolError("invalid-identity", "The stored browser identity is invalid.");
  validateDescriptor(value.descriptor);
  if (value.participantID !== value.descriptor.participantID) throw new ClipWebProtocolError("invalid-identity", "The stored browser identity is inconsistent.");
  const identityPrivate = await crypto.subtle.importKey("jwk", value.identityPrivateJWK, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const pairPrivate = await crypto.subtle.importKey("jwk", value.pairPrivateJWK, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const identityPublic = await importSigningPublic(decodeBase64URL(value.descriptor.identity, 65));
  const pairPublic = await importAgreementPublic(decodeBase64URL(value.descriptor.pairSignalingPublicKey, 65));
  return {
    identity: { privateKey: identityPrivate, publicKey: identityPublic },
    pairIdentity: { privateKey: pairPrivate, publicKey: pairPublic },
    participantID: decodeBase64URL(value.participantID, 16),
    descriptor: value.descriptor,
  };
}

function joinKnockCanonical(knock) {
  const encoder = new CanonicalEncoder("clip-live-share-server-room-v4/join-knock")
    .appendBytes(decodeBase64URL(knock.roomID, 32))
    .appendString(knock.sessionID)
    .appendBytes(descriptorCanonical(knock.descriptor))
    .appendBytes(decodeBase64URL(knock.admissionCapability, 32))
    .appendBool(knock.accessWordProof != null);
  if (knock.accessWordProof != null) encoder.appendBytes(decodeBase64URL(knock.accessWordProof, 32));
  return encoder.appendBool(knock.requiresCreatorApproval).appendBytes(decodeBase64Data(knock.nonce, 32)).data();
}

export async function makeAccessWordProof(accessWord, invite, descriptor) {
  const normalized = String(accessWord ?? "").trim().toUpperCase();
  if (!normalized || textEncoder.encode(normalized).length > 256) throw new ClipWebProtocolError("invalid-access-word", "Enter a valid Access Word.");
  const data = new CanonicalEncoder("clip-live-share-server-room-v4/access-word-proof")
    .appendBytes(decodeBase64URL(invite.roomId, 32))
    .appendString(invite.sessionId)
    .appendBytes(decodeBase64URL(descriptor.participantID, 16))
    .appendBytes(decodeBase64URL(descriptor.identity, 65))
    .appendBytes(decodeBase64URL(invite.admissionCapability, 32))
    .data();
  const key = await crypto.subtle.importKey("raw", textEncoder.encode(normalized), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return encodeBase64URL(await crypto.subtle.sign("HMAC", key, data));
}

export async function createJoinKnock(invite, identity, accessWord = null) {
  const knock = {
    roomID: invite.roomId,
    sessionID: invite.sessionId,
    descriptor: identity.descriptor,
    admissionCapability: invite.admissionCapability,
    requiresCreatorApproval: false,
    // Foundation's synthesized Codable representation for Data is canonical
    // padded base64 (unlike Clip's explicit base64url value wrappers).
    nonce: encodeBase64Data(randomBytes(32)),
  };
  if (accessWord) knock.accessWordProof = await makeAccessWordProof(accessWord, invite, identity.descriptor);
  const signature = await signRaw(identity.identity.privateKey, joinKnockCanonical(knock));
  return { knock, signature: encodeBase64URL(signature) };
}

function roomCipherAAD(invite, domain) {
  return new CanonicalEncoder(`clip-live-share-server-room-v4/room-cipher/${domain}`)
    .appendBytes(decodeBase64URL(invite.roomId, 32))
    .appendString(invite.sessionId)
    .data();
}

async function roomCipherKey(invite) {
  const secret = await crypto.subtle.importKey("raw", decodeBase64URL(invite.roomAgreementSecret, 32), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    {
      name: "HKDF", hash: "SHA-256", salt: decodeBase64URL(invite.roomId, 32),
      info: textEncoder.encode("clip-live-share-server-room-v4/room-cipher"),
    },
    secret,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export async function sealRoomValue(invite, domain, value) {
  const nonce = randomBytes(12);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: roomCipherAAD(invite, domain), tagLength: 128 },
    await roomCipherKey(invite),
    textEncoder.encode(JSON.stringify(value)),
  ));
  return encodeBase64URL(concatenate(nonce, ciphertext));
}

export async function openRoomValue(invite, domain, encoded) {
  const payload = decodeBase64URL(encoded);
  if (payload.length <= 28 || payload.length > 196000) throw new ClipWebProtocolError("invalid-room-value", "A protected room value is invalid.");
  let plaintext;
  try {
    plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: payload.slice(0, 12), additionalData: roomCipherAAD(invite, domain), tagLength: 128 },
      await roomCipherKey(invite),
      payload.slice(12),
    );
  } catch {
    throw new ClipWebProtocolError("room-authentication-failed", "A protected room value could not be authenticated.");
  }
  return strictJSON(plaintext);
}

export async function makeOpaqueJoinKnock(invite, identity, accessWord = null) {
  return sealRoomValue(invite, "join-knock", await createJoinKnock(invite, identity, accessWord));
}

function admissionCanonical(record) {
  return new CanonicalEncoder("clip-live-share-server-room-v4/admission-record")
    .appendBytes(decodeBase64URL(record.roomID, 32))
    .appendString(record.sessionID)
    .appendBytes(decodeBase64URL(record.memberHandle, 16))
    .appendBytes(descriptorCanonical(record.descriptor))
    .data();
}

export async function openAdmissionRecord(invite, encoded, expectedHandle = null) {
  const signed = await openRoomValue(invite, "admission-record", encoded);
  requireExactKeys(signed, ["record", "creatorSignature"]);
  const record = signed.record;
  requireExactKeys(record, ["roomID", "sessionID", "memberHandle", "descriptor"]);
  if (record.roomID !== invite.roomId || record.sessionID !== invite.sessionId || (expectedHandle && record.memberHandle !== expectedHandle)) {
    throw new ClipWebProtocolError("admission-context-mismatch", "A participant admission belongs to another room.");
  }
  validateDescriptor(record.descriptor);
  const valid = await verifyRaw(
    await importSigningPublic(decodeBase64URL(invite.creatorIdentity, 65)),
    decodeBase64URL(signed.creatorSignature, 64),
    admissionCanonical(record),
  );
  if (!valid) throw new ClipWebProtocolError("invalid-admission-signature", "A participant admission is not signed by the room creator.");
  return record;
}

export async function derivePairContext(invite, localHandle, localParticipantID, remoteHandle, remoteParticipantID) {
  decodeBase64URL(localHandle, 16); decodeBase64URL(remoteHandle, 16);
  const localPID = decodeBase64URL(localParticipantID, 16);
  const remotePID = decodeBase64URL(remoteParticipantID, 16);
  if (localHandle === remoteHandle || localParticipantID === remoteParticipantID) throw new ClipWebProtocolError("invalid-pair", "A peer pair requires two different participants.");
  const localIsLowerHandle = localHandle < remoteHandle;
  const lowerHandle = localIsLowerHandle ? localHandle : remoteHandle;
  const upperHandle = localIsLowerHandle ? remoteHandle : localHandle;
  const lowerParticipantID = localIsLowerHandle ? localParticipantID : remoteParticipantID;
  const upperParticipantID = localIsLowerHandle ? remoteParticipantID : localParticipantID;
  const pairID = encodeBase64URL(await sha256(textEncoder.encode(
    `clip-native-room-v4-pair\0${invite.roomId}\0${lowerHandle}\0${upperHandle}`,
  )));
  const context = { roomId: invite.roomId, sessionId: invite.sessionId, lowerHandle, upperHandle, lowerParticipantId: lowerParticipantID, upperParticipantId: upperParticipantID, pairId: pairID };
  return {
    ...context,
    localHandle,
    remoteHandle,
    localParticipantID,
    remoteParticipantID,
    initialOfferer: lexicographicBytes(localPID, remotePID) < 0 ? localHandle : remoteHandle,
  };
}

function pairContextCanonical(context) {
  return new CanonicalEncoder("clip-live-share-server-room-v4/pair-context")
    .appendBytes(decodeBase64URL(context.roomId, 32))
    .appendString(context.sessionId)
    .appendBytes(decodeBase64URL(context.lowerHandle, 16))
    .appendBytes(decodeBase64URL(context.upperHandle, 16))
    .appendBytes(decodeBase64URL(context.lowerParticipantId, 16))
    .appendBytes(decodeBase64URL(context.upperParticipantId, 16))
    .appendBytes(decodeBase64URL(context.pairId, 32))
    .data();
}

function lexicographicBytes(left, right) {
  for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return left.length - right.length;
}

function pairPayloadCanonical(payload) {
  const encoder = new CanonicalEncoder("clip-live-share-server-room-v4/pair-signal-payload");
  switch (payload.type) {
    case "offer": case "answer":
      return encoder.appendString(payload.type).appendUInt64(payload.epoch).appendString(payload.sdp).data();
    case "ice-candidate":
      encoder.appendString(payload.type).appendUInt64(payload.epoch).appendString(payload.candidate)
        .appendBool(payload.mediaId != null);
      if (payload.mediaId != null) encoder.appendString(payload.mediaId);
      encoder.appendBool(payload.mediaLineIndex != null);
      if (payload.mediaLineIndex != null) encoder.appendUInt64(payload.mediaLineIndex);
      return encoder.data();
    case "ice-restart": case "renegotiation-request":
      return encoder.appendString(payload.type).appendUInt64(payload.epoch).data();
    case "codec-renegotiation-request": case "codec-renegotiation-rejected":
      return encoder.appendString(payload.type).appendUInt64(payload.epoch).appendString(payload.codec).data();
    case "close": return encoder.appendString("close").data();
    default: throw new ClipWebProtocolError("invalid-pair-signal", "A peer signaling message is unsupported.");
  }
}

function pairSignatureCanonical(context, payload, from, to, sequence) {
  return new CanonicalEncoder("clip-live-share-server-room-v4/pair-signal-signature")
    .appendBytes(pairContextCanonical(context))
    .appendBytes(decodeBase64URL(from, 16))
    .appendBytes(decodeBase64URL(to, 16))
    .appendUInt64(sequence)
    .appendBytes(pairPayloadCanonical(payload))
    .data();
}

function pairAAD(context, from, to, sequence) {
  return new CanonicalEncoder("clip-live-share-server-room-v4/pair-envelope")
    .appendBytes(pairContextCanonical(context))
    .appendBytes(decodeBase64URL(from, 16))
    .appendBytes(decodeBase64URL(to, 16))
    .appendUInt64(sequence)
    .data();
}

export class EncryptedPairChannel {
  static async create({ context, localIdentity, remoteDescriptor, sequenceState = null }) {
    const remotePublic = await importAgreementPublic(decodeBase64URL(remoteDescriptor.pairSignalingPublicKey, 65));
    const bits = await crypto.subtle.deriveBits(
      { name: "ECDH", public: remotePublic },
      localIdentity.pairIdentity.privateKey,
      256,
    );
    const hkdf = await crypto.subtle.importKey("raw", bits, "HKDF", false, ["deriveKey"]);
    const salt = await sha256(pairContextCanonical(context));
    const derive = (from, to) => crypto.subtle.deriveKey(
      {
        name: "HKDF", hash: "SHA-256", salt,
        info: new CanonicalEncoder("clip-live-share-server-room-v4/pair-key")
          .appendBytes(decodeBase64URL(from, 16)).appendBytes(decodeBase64URL(to, 16)).data(),
      },
      hkdf,
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
    return new EncryptedPairChannel({
      context,
      localIdentity,
      remoteDescriptor,
      outboundKey: await derive(context.localHandle, context.remoteHandle),
      inboundKey: await derive(context.remoteHandle, context.localHandle),
      sequenceState,
    });
  }

  constructor({ context, localIdentity, remoteDescriptor, outboundKey, inboundKey, sequenceState }) {
    this.context = context;
    this.localIdentity = localIdentity;
    this.remoteDescriptor = remoteDescriptor;
    this.outboundKey = outboundKey;
    this.inboundKey = inboundKey;
    this.outboundSequence = validSequence(sequenceState?.outbound) ? sequenceState.outbound : 0;
    this.inboundSequence = validSequence(sequenceState?.inbound) ? sequenceState.inbound : 0;
  }

  async seal(payload) {
    const sequence = this.outboundSequence + 1;
    const signature = await signRaw(
      this.localIdentity.identity.privateKey,
      pairSignatureCanonical(this.context, payload, this.context.localHandle, this.context.remoteHandle, sequence),
    );
    const plaintext = textEncoder.encode(JSON.stringify({ payload, signature: encodeBase64URL(signature) }));
    const nonce = randomBytes(12);
    const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: pairAAD(this.context, this.context.localHandle, this.context.remoteHandle, sequence), tagLength: 128 },
      this.outboundKey,
      plaintext,
    ));
    this.outboundSequence = sequence;
    return {
      type: "pair-signal", version: VERSION, sequence,
      payload: encodeBase64URL(concatenate(nonce, ciphertext)),
      to: this.context.remoteHandle, pairId: this.context.pairId,
    };
  }

  async open(envelope) {
    if (envelope.from !== this.context.remoteHandle || envelope.to !== this.context.localHandle || envelope.pairId !== this.context.pairId) {
      throw new ClipWebProtocolError("pair-context-mismatch", "A signaling message belongs to another peer pair.");
    }
    if (!Number.isSafeInteger(envelope.sequence) || envelope.sequence <= this.inboundSequence) {
      throw new ClipWebProtocolError("pair-sequence", "A replayed peer signaling message was rejected.");
    }
    const encoded = decodeBase64URL(envelope.payload);
    let plaintext;
    try {
      plaintext = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: encoded.slice(0, 12), additionalData: pairAAD(this.context, this.context.remoteHandle, this.context.localHandle, envelope.sequence), tagLength: 128 },
        this.inboundKey,
        encoded.slice(12),
      );
    } catch {
      throw new ClipWebProtocolError("pair-authentication", "Peer signaling authentication failed.");
    }
    const signed = strictJSON(plaintext, ["payload", "signature"]);
    const valid = await verifyRaw(
      await importSigningPublic(decodeBase64URL(this.remoteDescriptor.identity, 65)),
      decodeBase64URL(signed.signature, 64),
      pairSignatureCanonical(this.context, signed.payload, this.context.remoteHandle, this.context.localHandle, envelope.sequence),
    );
    if (!valid) throw new ClipWebProtocolError("pair-signature", "A peer signaling signature is invalid.");
    this.inboundSequence = envelope.sequence;
    return signed.payload;
  }
}

function validSequence(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

export const __test = Object.freeze({
  descriptorCanonical,
  joinKnockCanonical,
  admissionCanonical,
  pairContextCanonical,
  pairPayloadCanonical,
  pairSignatureCanonical,
  pairAAD,
  roomCipherAAD,
  equalBytes,
});
