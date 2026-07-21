export const CLIP_PROTOCOL = "clip-live-share";
export const CLIP_PROTOCOL_VERSION = 1;
export const MAX_OUTER_MESSAGE_BYTES = 262_144;
export const MAX_INNER_MESSAGE_BYTES = 196_400;
export const MAX_ICE_CANDIDATES = 256;
export const MAX_SESSION_DESCRIPTION_BYTES = 190_000;
export const MAX_ICE_CANDIDATE_BYTES = 16_384;

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

export class ClipProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ClipProtocolError";
    this.code = code;
  }
}

export function normalizeRoom(value) {
  const room = String(value ?? "").trim().toUpperCase();
  if (
    room.length < 3 ||
    room.length > 64 ||
    !/^[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?$/.test(room)
  ) {
    throw new ClipProtocolError("invalid-room", "This share link has an invalid room name.");
  }
  return room;
}

export function normalizeAccessCode(value) {
  return String(value ?? "").trim().toUpperCase();
}

export function encodeBase64URL(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

export function decodeBase64URL(value, expectedLength = null) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value) || value.length % 4 === 1) {
    throw new ClipProtocolError("invalid-base64url", "A signaling value is not valid base64url.");
  }
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  let binary;
  try {
    binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
  } catch {
    throw new ClipProtocolError("invalid-base64url", "A signaling value is not valid base64url.");
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (encodeBase64URL(bytes) !== value) {
    throw new ClipProtocolError("invalid-base64url", "A signaling value is not canonical base64url.");
  }
  if (expectedLength !== null && bytes.length !== expectedLength) {
    throw new ClipProtocolError(
      "invalid-length",
      `A signaling value has ${bytes.length} bytes; expected ${expectedLength}.`,
    );
  }
  return bytes;
}

export function parseViewerFragment(hash = window.location.hash) {
  const value = String(hash).replace(/^#/u, "");
  if (value.length === 0 || encoder.encode(value).length > 1_024) {
    throw new ClipProtocolError("invalid-fragment", "This share link has an invalid URL fragment.");
  }
  const fields = new Map();
  for (const component of value.split("&")) {
    const separator = component.indexOf("=");
    if (separator < 0) {
      throw new ClipProtocolError("invalid-fragment", "This share link has an invalid URL fragment.");
    }
    const name = component.slice(0, separator);
    const fieldValue = component.slice(separator + 1);
    if ((name !== "v" && name !== "key") || fields.has(name)) {
      throw new ClipProtocolError("invalid-fragment", "This share link has invalid URL fragment fields.");
    }
    fields.set(name, fieldValue);
  }
  if (fields.size !== 2 || !fields.has("v") || !fields.has("key")) {
    throw new ClipProtocolError("invalid-fragment", "This share link has an incomplete URL fragment.");
  }
  const versionValue = fields.get("v");
  if (!/^[+-]?\d+$/u.test(versionValue) || Number(versionValue) !== CLIP_PROTOCOL_VERSION) {
    throw new ClipProtocolError(
      "unsupported-version",
      "This share link uses an unsupported Clip Live Share version.",
    );
  }
  const encodedKey = fields.get("key");
  if (!encodedKey) {
    throw new ClipProtocolError("missing-room-key", "This share link is missing its room key.");
  }
  const roomPublicKey = decodeBase64URL(encodedKey, 65);
  if (roomPublicKey[0] !== 0x04) {
    throw new ClipProtocolError("invalid-room-key", "This share link contains an invalid room key.");
  }
  return { version: CLIP_PROTOCOL_VERSION, roomPublicKey };
}

export function fillPathTemplate(template, room) {
  if (
    typeof template !== "string" ||
    !template.startsWith("/") ||
    template.split("{room}").length !== 2 ||
    encoder.encode(template).length > 2_048 ||
    template.includes("?") ||
    template.includes("#") ||
    template.includes("\\") ||
    template.includes("..")
  ) {
    throw new ClipProtocolError("invalid-capabilities", "The server returned an invalid viewer route.");
  }
  return template.replace("{room}", room);
}

export function websocketURL(path, locationValue = window.location) {
  const protocol = locationValue.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${locationValue.host}${path.startsWith("/") ? path : `/${path}`}`;
}

export function validateCapabilities(value) {
  if (
    !value ||
    value.protocol !== CLIP_PROTOCOL ||
    !Array.isArray(value.versions) ||
    value.versions.length < 1 ||
    value.versions.length > 32 ||
    value.versions.some((version) => !Number.isSafeInteger(version)) ||
    new Set(value.versions).size !== value.versions.length ||
    !value.versions.includes(CLIP_PROTOCOL_VERSION) ||
    !isRequiredText(value.serverVersion, 128)
  ) {
    throw new ClipProtocolError(
      "unsupported-server",
      "This server does not support Clip Live Share protocol v1.",
    );
  }
  for (const template of [
    value.viewerPathTemplate,
    value.hostWebSocketPathTemplate,
    value.viewerWebSocketPathTemplate,
  ]) {
    fillPathTemplate(template, "ROOM");
  }
  if (!value.limits || typeof value.limits !== "object") {
    throw new ClipProtocolError("invalid-capabilities", "The server did not provide a viewer route.");
  }
  const maximumMessageBytes = value.limits.maximumMessageBytes;
  if (
    !Number.isSafeInteger(maximumMessageBytes) ||
    maximumMessageBytes < 1 ||
    maximumMessageBytes > MAX_OUTER_MESSAGE_BYTES ||
    !Number.isSafeInteger(value.limits.maximumPendingViewersPerRoom) ||
    value.limits.maximumPendingViewersPerRoom < 1 ||
    value.limits.maximumPendingViewersPerRoom > 8
  ) {
    throw new ClipProtocolError("invalid-capabilities", "The server returned an unsafe message limit.");
  }
  if (!Array.isArray(value.iceServers) || value.iceServers.length > 32) {
    throw new ClipProtocolError("invalid-capabilities", "The server returned invalid ICE servers.");
  }
  const iceServers = value.iceServers.map((entry) => {
    if (
      !entry ||
      !Array.isArray(entry.urls) ||
      entry.urls.length < 1 ||
      entry.urls.length > 16 ||
      entry.urls.some(
        (url) =>
          typeof url !== "string" ||
          utf8Length(url) > 2_048 ||
          !/^(?:stun|stuns|turn|turns):/iu.test(url),
      ) ||
      (entry.username != null &&
        (typeof entry.username !== "string" || utf8Length(entry.username) > 1_024)) ||
      (entry.credential != null &&
        (typeof entry.credential !== "string" || utf8Length(entry.credential) > 4_096))
    ) {
      throw new ClipProtocolError("invalid-capabilities", "The server returned invalid ICE servers.");
    }
    return {
      urls: [...entry.urls],
      ...(entry.username == null ? {} : { username: entry.username }),
      ...(entry.credential == null ? {} : { credential: entry.credential }),
    };
  });
  return {
    viewerWebSocketPathTemplate: value.viewerWebSocketPathTemplate,
    maximumMessageBytes,
    iceServers,
  };
}

export function signalingAAD(room, routeId, direction, sequence) {
  return encoder.encode(
    `${CLIP_PROTOCOL}|${CLIP_PROTOCOL_VERSION}|${room}|${routeId}|${direction}|${sequence}`,
  );
}

export function signalingSaltInput(room, routeId) {
  return encoder.encode(`${CLIP_PROTOCOL}|${CLIP_PROTOCOL_VERSION}|${room}|${routeId}`);
}

export async function createViewerKeyPair(subtle = crypto.subtle) {
  const keyPair = await subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
  const publicKey = new Uint8Array(await subtle.exportKey("raw", keyPair.publicKey));
  if (publicKey.length !== 65 || publicKey[0] !== 0x04) {
    throw new ClipProtocolError("key-generation-failed", "The browser generated an invalid viewer key.");
  }
  return { privateKey: keyPair.privateKey, publicKey };
}

export async function deriveRouteKeys({
  privateKey,
  roomPublicKey,
  room,
  routeId,
  subtle = crypto.subtle,
}) {
  const hostPublicKey = await subtle.importKey(
    "raw",
    roomPublicKey,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const sharedSecret = await subtle.deriveBits(
    { name: "ECDH", public: hostPublicKey },
    privateKey,
    256,
  );
  const hkdfKey = await subtle.importKey("raw", sharedSecret, "HKDF", false, ["deriveKey"]);
  const salt = await subtle.digest("SHA-256", signalingSaltInput(room, routeId));
  const derive = (info) => subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt,
      info: encoder.encode(info),
    },
    hkdfKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
  return {
    outboundKey: await derive("viewer-to-host"),
    inboundKey: await derive("host-to-viewer"),
  };
}

export class EncryptedRoute {
  constructor({ room, routeId, outboundKey, inboundKey, subtle = crypto.subtle }) {
    this.room = normalizeRoom(room);
    this.routeId = String(routeId);
    decodeBase64URL(this.routeId, 16);
    this.outboundKey = outboundKey;
    this.inboundKey = inboundKey;
    this.subtle = subtle;
    this.outboundSequence = 0;
    this.inboundSequence = 0;
  }

  async seal(message) {
    const plaintext = encoder.encode(JSON.stringify(message));
    if (plaintext.length === 0 || plaintext.length > MAX_INNER_MESSAGE_BYTES) {
      throw new ClipProtocolError("message-too-large", "The signaling message is too large.");
    }
    const sequence = this.outboundSequence + 1;
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await this.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: nonce,
        additionalData: signalingAAD(this.room, this.routeId, "viewer-to-host", sequence),
        tagLength: 128,
      },
      this.outboundKey,
      plaintext,
    );
    this.outboundSequence = sequence;
    return {
      type: "relay",
      sequence,
      nonce: encodeBase64URL(nonce),
      ciphertext: encodeBase64URL(ciphertext),
    };
  }

  async open(envelope) {
    if (!envelope || envelope.type !== "relay" || envelope.routeId !== this.routeId) {
      throw new ClipProtocolError("route-mismatch", "The signaling message belongs to another route.");
    }
    const expectedSequence = this.inboundSequence + 1;
    if (!Number.isSafeInteger(envelope.sequence) || envelope.sequence !== expectedSequence) {
      throw new ClipProtocolError(
        "invalid-sequence",
        `Expected signaling sequence ${expectedSequence}.`,
      );
    }
    const nonce = decodeBase64URL(envelope.nonce, 12);
    const ciphertext = decodeBase64URL(envelope.ciphertext);
    if (ciphertext.length < 16 || ciphertext.length > MAX_INNER_MESSAGE_BYTES + 16) {
      throw new ClipProtocolError("invalid-ciphertext", "The encrypted signaling message is invalid.");
    }
    let plaintext;
    try {
      plaintext = await this.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: nonce,
          additionalData: signalingAAD(
            this.room,
            this.routeId,
            "host-to-viewer",
            envelope.sequence,
          ),
          tagLength: 128,
        },
        this.inboundKey,
        ciphertext,
      );
    } catch {
      throw new ClipProtocolError("authentication-failed", "Encrypted signaling authentication failed.");
    }
    if (plaintext.byteLength === 0 || plaintext.byteLength > MAX_INNER_MESSAGE_BYTES) {
      throw new ClipProtocolError("message-too-large", "The signaling message is too large.");
    }
    let value;
    try {
      value = JSON.parse(decoder.decode(plaintext));
    } catch {
      throw new ClipProtocolError("invalid-message", "The host sent invalid encrypted signaling.");
    }
    this.inboundSequence = envelope.sequence;
    return value;
  }
}

export async function createAuthProof({
  accessCode,
  challenge,
  sessionId,
  subtle = crypto.subtle,
}) {
  const normalizedCode = normalizeAccessCode(accessCode);
  if (!normalizedCode) {
    throw new ClipProtocolError("missing-access-code", "Enter the access code to continue.");
  }
  const codeHash = await subtle.digest("SHA-256", encoder.encode(normalizedCode));
  const key = await subtle.importKey(
    "raw",
    codeHash,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const challengeBytes = decodeBase64URL(challenge, 32);
  const sessionBytes = encoder.encode(String(sessionId));
  const input = new Uint8Array(challengeBytes.length + sessionBytes.length);
  input.set(challengeBytes, 0);
  input.set(sessionBytes, challengeBytes.length);
  return encodeBase64URL(await subtle.sign("HMAC", key, input));
}

export function utf8Length(value) {
  return typeof value === "string" ? encoder.encode(value).length : -1;
}

export function isOpaqueIdentifier(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(value);
}

export function isRequiredText(value, maximum) {
  const length = utf8Length(value);
  return length >= 1 && length <= maximum;
}

export function isOptionalText(value, maximum) {
  return value === undefined || value === null || isRequiredText(value, maximum);
}

export function canonicalProtocolFailure(value) {
  if (
    !value ||
    !isRequiredText(value.code, 64) ||
    !/^[A-Za-z0-9_-]+$/u.test(value.code) ||
    !isRequiredText(value.message, 256)
  ) {
    throw new ClipProtocolError("invalid-error", "The peer sent an invalid protocol error.");
  }
  return { code: value.code, message: value.message };
}

export function createInnerProtocolFailure(sessionId, code, message) {
  if (!isOpaqueIdentifier(sessionId)) {
    throw new ClipProtocolError("invalid-session", "The viewer has no valid Clip session.");
  }
  const failure = canonicalProtocolFailure({ code, message });
  return {
    type: "error",
    version: CLIP_PROTOCOL_VERSION,
    sessionId,
    ...failure,
  };
}

export function canonicalSystemAudioState(value) {
  if (!value || typeof value.enabled !== "boolean") {
    throw new ClipProtocolError(
      "invalid-system-audio-state",
      "Clip sent an invalid system-audio state.",
    );
  }
  return value.enabled;
}

/**
 * Keeps asynchronous WebRTC work tied to the exact peer that began it.
 * A reconnect can replace the global RTCPeerConnection while an SDP promise
 * is suspended; generation and identity must both match before completion is
 * allowed to mutate viewer state.
 */
export class PeerGenerationGuard {
  constructor() {
    this.generation = 0;
    this.connection = null;
  }

  replace(connection) {
    this.generation += 1;
    this.connection = connection;
    return this.generation;
  }

  clear() {
    this.generation += 1;
    this.connection = null;
    return this.generation;
  }

  isCurrent(connection, generation) {
    return this.connection === connection && this.generation === generation;
  }
}

export function assertInnerMessage(message, sessionId = null) {
  if (!message || message.version !== CLIP_PROTOCOL_VERSION || typeof message.type !== "string") {
    throw new ClipProtocolError("invalid-message", "The host sent an invalid protocol message.");
  }
  if (!isOpaqueIdentifier(message.sessionId)) {
    throw new ClipProtocolError("invalid-session", "The host sent an invalid session identifier.");
  }
  if (sessionId !== null && message.sessionId !== sessionId) {
    throw new ClipProtocolError("session-mismatch", "The signaling message belongs to another session.");
  }
  return message;
}

export function canonicalManifest(value) {
  if (!value || !Array.isArray(value.streams) || value.streams.length > 64) {
    throw new ClipProtocolError("invalid-manifest", "Clip sent an invalid stream manifest.");
  }
  const source = value.streams;
  const seen = new Set();
  const seenTracks = new Set();
  const seenOrders = new Set();
  const streams = [];
  for (const entry of source) {
    const id = entry?.id;
    const mediaTrackId = entry?.mediaTrackId;
    const hasSourcePointWidth = entry?.sourcePointWidth !== undefined;
    const hasSourcePointHeight = entry?.sourcePointHeight !== undefined;
    const sourcePointWidth = hasSourcePointWidth
      ? entry.sourcePointWidth
      : entry?.width;
    const sourcePointHeight = hasSourcePointHeight
      ? entry.sourcePointHeight
      : entry?.height;
    if (
      !isOpaqueIdentifier(id) ||
      !isOpaqueIdentifier(mediaTrackId) ||
      seen.has(id) ||
      seenTracks.has(mediaTrackId) ||
      seenOrders.has(entry.order) ||
      typeof entry.active !== "boolean" ||
      typeof entry.focused !== "boolean" ||
      typeof entry.appName !== "string" ||
      typeof entry.windowName !== "string" ||
      encoder.encode(entry.appName).length > 512 ||
      encoder.encode(entry.windowName).length > 1_024 ||
      !Number.isSafeInteger(entry.width) ||
      !Number.isSafeInteger(entry.height) ||
      entry.width < 1 ||
      entry.height < 1 ||
      entry.width > 32_768 ||
      entry.height > 32_768 ||
      hasSourcePointWidth !== hasSourcePointHeight ||
      !Number.isSafeInteger(sourcePointWidth) ||
      !Number.isSafeInteger(sourcePointHeight) ||
      sourcePointWidth < 1 ||
      sourcePointHeight < 1 ||
      sourcePointWidth > 32_768 ||
      sourcePointHeight > 32_768 ||
      !Number.isSafeInteger(entry.order) ||
      entry.order < 0 ||
      entry.order > 65_535
    ) {
      throw new ClipProtocolError("invalid-manifest", "Clip sent an invalid stream manifest.");
    }
    seen.add(id);
    seenTracks.add(mediaTrackId);
    seenOrders.add(entry.order);
    const normalized = {
      id,
      mediaTrackId,
      active: entry.active,
      focused: entry.focused,
      appName: entry.appName,
      windowName: entry.windowName,
      width: entry.width,
      height: entry.height,
      order: entry.order,
    };
    if (hasSourcePointWidth) {
      normalized.sourcePointWidth = sourcePointWidth;
      normalized.sourcePointHeight = sourcePointHeight;
    }
    streams.push(normalized);
  }
  if (streams.filter((entry) => entry.focused).length > 1) {
    throw new ClipProtocolError("invalid-manifest", "Clip focused more than one stream.");
  }
  if (streams.some((entry) => entry.focused && !entry.active)) {
    throw new ClipProtocolError("invalid-manifest", "Clip focused an inactive stream.");
  }
  streams.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id));
  return streams;
}

// Keeps encoded pixel dimensions separate from the CSS size of the source
// window. `videoWidth` remains the decode truth; logical points are the
// presentation truth when a current host provides them.
export function presentationSize(info, video = null) {
  const encodedWidth = info?.width ?? video?.videoWidth ?? 0;
  const encodedHeight = info?.height ?? video?.videoHeight ?? 0;
  const width = info?.sourcePointWidth ?? encodedWidth;
  const height = info?.sourcePointHeight ?? encodedHeight;
  return {
    width: Number.isFinite(width) && width > 0 ? width : 0,
    height: Number.isFinite(height) && height > 0 ? height : 0,
  };
}
