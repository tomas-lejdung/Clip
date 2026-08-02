const VERSION = 4;
const ROOM_CODE_PATTERN = /^[A-Z0-9]{8}$/;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const INVITE_DOMAIN = "clip-live-share-server-room-v4/invite";
const HKDF_SALT = "clip-live-share-server-room-v4/invite/salt";
const HKDF_INFO = "clip-live-share-server-room-v4/invite/payload";
const PAYLOAD_KEYS = [
  "admissionCapability",
  "creatorIdentity",
  "roomAgreementSecret",
  "roomId",
  "sessionId",
  "version",
];

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: true });

/**
 * Opens Clip's canonical native-room v4 invite in a browser-compatible way.
 *
 * The returned object contains private room material. Callers must keep it in
 * memory, never log it, never persist it in history/analytics, and never send
 * the URL fragment to the room service.
 */
export async function openClipServerRoomV4Invite(value) {
  const url = value instanceof URL ? new URL(value.href) : new URL(value);
  if (
    (url.protocol !== "https:" && url.protocol !== "http:") ||
    url.username !== "" ||
    url.password !== "" ||
    url.search !== ""
  ) {
    throw new Error("Invalid Clip room service URL");
  }

  const pathMatch = /^\/([A-Z0-9]{8})$/.exec(url.pathname);
  if (!pathMatch || !ROOM_CODE_PATTERN.test(pathMatch[1])) {
    throw new Error("Invalid Clip room code path");
  }
  const roomCode = pathMatch[1];

  const fields = url.hash.slice(1).split("&");
  if (
    fields.length !== 3 ||
    fields[0] !== "v=4" ||
    !fields[1].startsWith("key=") ||
    !fields[2].startsWith("join=")
  ) {
    throw new Error("Invalid Clip invite fragment");
  }
  const sealedPayload = decodeBase64URL(fields[1].slice(4));
  const admissionCapability = decodeBase64URL(fields[2].slice(5), 32);
  if (sealedPayload.byteLength <= 12 + 16 || sealedPayload.byteLength > 8 * 1024) {
    throw new Error("Invalid Clip invite payload length");
  }

  const inputKey = await globalThis.crypto.subtle.importKey(
    "raw",
    admissionCapability,
    "HKDF",
    false,
    ["deriveKey"],
  );
  const encryptionKey = await globalThis.crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: textEncoder.encode(HKDF_SALT),
      info: textEncoder.encode(HKDF_INFO),
    },
    inputKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
  const plaintext = await globalThis.crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: sealedPayload.slice(0, 12),
      additionalData: inviteAuthenticatedData(roomCode),
      tagLength: 128,
    },
    encryptionKey,
    sealedPayload.slice(12),
  );
  const payload = JSON.parse(textDecoder.decode(plaintext));
  requireExactObjectKeys(payload, PAYLOAD_KEYS);
  if (
    payload.version !== VERSION ||
    typeof payload.sessionId !== "string" ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(payload.sessionId)
  ) {
    throw new Error("Invalid Clip invite payload");
  }

  decodeBase64URL(payload.roomId, 32);
  const creatorIdentity = decodeBase64URL(payload.creatorIdentity, 65);
  await globalThis.crypto.subtle.importKey(
    "raw",
    creatorIdentity,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  decodeBase64URL(payload.roomAgreementSecret, 32);
  const payloadAdmission = decodeBase64URL(payload.admissionCapability, 32);
  if (!equalBytes(payloadAdmission, admissionCapability)) {
    throw new Error("Clip admission capability does not match its payload");
  }

  return Object.freeze({
    version: VERSION,
    serviceEndpoint: url.origin,
    serviceRoomURL: `${url.origin}/${roomCode}`,
    roomCode,
    roomId: payload.roomId,
    sessionId: payload.sessionId,
    creatorIdentity: payload.creatorIdentity,
    roomAgreementSecret: payload.roomAgreementSecret,
    admissionCapability: payload.admissionCapability,
  });
}

function inviteAuthenticatedData(roomCode) {
  const domain = textEncoder.encode(INVITE_DOMAIN);
  const path = textEncoder.encode(`/${roomCode}`);
  return concatenate(
    uint32(domain.byteLength),
    domain,
    uint64(VERSION),
    uint32(path.byteLength),
    path,
  );
}

function decodeBase64URL(value, expectedByteCount) {
  if (!BASE64URL_PATTERN.test(value) || value.includes("=")) {
    throw new Error("Invalid canonical base64url value");
  }
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (encodeBase64URL(bytes) !== value) {
    throw new Error("Noncanonical base64url value");
  }
  if (expectedByteCount !== undefined && bytes.byteLength !== expectedByteCount) {
    throw new Error("Invalid decoded value length");
  }
  return bytes;
}

function encodeBase64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function requireExactObjectKeys(value, expected) {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error("Invalid Clip invite payload object");
  }
  const actual = Object.keys(value).sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error("Invalid Clip invite payload keys");
  }
}

function equalBytes(lhs, rhs) {
  if (lhs.byteLength !== rhs.byteLength) return false;
  let difference = 0;
  for (let index = 0; index < lhs.byteLength; index += 1) {
    difference |= lhs[index] ^ rhs[index];
  }
  return difference === 0;
}

function concatenate(...values) {
  const result = new Uint8Array(values.reduce((count, value) => count + value.byteLength, 0));
  let offset = 0;
  for (const value of values) {
    result.set(value, offset);
    offset += value.byteLength;
  }
  return result;
}

function uint32(value) {
  const result = new Uint8Array(4);
  new DataView(result.buffer).setUint32(0, value, false);
  return result;
}

function uint64(value) {
  const result = new Uint8Array(8);
  new DataView(result.buffer).setBigUint64(0, BigInt(value), false);
  return result;
}
