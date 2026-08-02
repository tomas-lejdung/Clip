import { decodeBase64URL } from "./clip-room-crypto.js";

export function chooseFollowParticipant({
  participantOrder,
  sourcesByParticipant,
  currentParticipantID = null,
}) {
  const active = participantOrder.filter((participantID) =>
    (sourcesByParticipant.get(participantID) ?? []).some((source) => source.active),
  );
  if (active.length === 0) return null;
  if (currentParticipantID && active.includes(currentParticipantID)) return currentParticipantID;
  return active[0];
}

export function chooseFollowSource(sources, currentSourceKey = null) {
  const active = [...sources]
    .filter((source) => source.active)
    .sort((left, right) => left.order - right.order || left.key.localeCompare(right.key));
  if (active.length === 0) return null;
  const current = active.find((source) => source.key === currentSourceKey);
  if (current) return current;
  return active.find((source) => source.focused) ?? active[0];
}

export function reconcileFollowState({
  participantOrder,
  sourcesByParticipant,
  followParticipantID,
  selectedSourceKey,
}) {
  const participantID = chooseFollowParticipant({
    participantOrder,
    sourcesByParticipant,
    currentParticipantID: followParticipantID,
  });
  if (!participantID) return { followParticipantID: null, selectedSourceKey: null };
  const source = chooseFollowSource(
    sourcesByParticipant.get(participantID) ?? [],
    followParticipantID === participantID ? selectedSourceKey : null,
  );
  const selectedSource = selectedSourceKey && followParticipantID === participantID
    ? (sourcesByParticipant.get(participantID) ?? []).find((entry) => entry.active && entry.key === selectedSourceKey)
    : null;
  return {
    followParticipantID: participantID,
    // `selectedSourceKey` represents an explicit click by the viewer. Do not
    // turn the automatically chosen focused source into a pin: a later native
    // focus update must remain able to move Follow to the new focused window.
    selectedSourceKey: selectedSource ? source?.key ?? null : null,
  };
}

export function createAnimationFrameCoalescer(callback, scheduleFrame = requestAnimationFrame, cancelFrame = cancelAnimationFrame) {
  let frame = null;
  const schedule = () => {
    if (frame !== null) return;
    frame = scheduleFrame(() => {
      frame = null;
      callback();
    });
  };
  schedule.cancel = () => {
    if (frame === null) return;
    cancelFrame(frame);
    frame = null;
  };
  return schedule;
}

export function validateSourceSnapshot(message, expected) {
  requireExactKeys(message, ["version", "type", "payload"]);
  if (!message || message.version !== 4 || message.type !== "source-snapshot") {
    throw new Error("Unsupported control message");
  }
  const value = message.payload;
  requireExactKeys(value, ["version", "sessionId", "membershipRevision", "ownerParticipantId", "sourceRevision", "sources"]);
  if (!value || value.version !== 3 || value.sessionId !== expected.sessionId || value.ownerParticipantId !== expected.ownerParticipantID) {
    throw new Error("Source snapshot context mismatch");
  }
  if (value.membershipRevision !== 1 || !Number.isSafeInteger(value.sourceRevision) || value.sourceRevision < 1) {
    throw new Error("Invalid source revision");
  }
  if (!Array.isArray(value.sources) || value.sources.length > 4) throw new Error("Invalid source count");
  const keys = new Set();
  const tracks = new Set();
  const orders = new Set();
  let focusCount = 0;
  const sources = value.sources.map((published) => {
    requireExactKeys(published, ["key", "descriptor"]);
    const key = published?.key;
    const descriptor = published?.descriptor;
    const stream = descriptor?.stream;
    requireExactKeys(key, ["ownerParticipantId", "sourceInstanceId"]);
    requireExactKeys(descriptor, ["sourceInstanceId", "stream"]);
    requireExactKeys(stream, [
      "id", "mediaTrackId", "active", "focused", "appName", "windowName",
      "width", "height", "order", "sourcePointWidth", "sourcePointHeight",
    ]);
    if (
      !key || key.ownerParticipantId !== expected.ownerParticipantID ||
      !validSourceInstanceID(key.sourceInstanceId) || descriptor?.sourceInstanceId !== key.sourceInstanceId ||
      !stream || !validOpaqueID(stream.id) || !validOpaqueID(stream.mediaTrackId) ||
      typeof stream.active !== "boolean" || typeof stream.focused !== "boolean" ||
      !validText(stream.appName, 512) || !validText(stream.windowName, 1024) ||
      !Number.isSafeInteger(stream.width) || stream.width < 1 || stream.width > 32768 ||
      !Number.isSafeInteger(stream.height) || stream.height < 1 || stream.height > 32768 ||
      !Number.isSafeInteger(stream.sourcePointWidth) || stream.sourcePointWidth < 1 || stream.sourcePointWidth > 32768 ||
      !Number.isSafeInteger(stream.sourcePointHeight) || stream.sourcePointHeight < 1 || stream.sourcePointHeight > 32768 ||
      !Number.isSafeInteger(stream.order) || stream.order < 0 || stream.order > 65535 ||
      (stream.focused && !stream.active)
    ) throw new Error("Invalid source descriptor");
    const sourceKey = `${key.ownerParticipantId}:${key.sourceInstanceId}`;
    if (keys.has(sourceKey) || tracks.has(stream.mediaTrackId) || orders.has(stream.order)) throw new Error("Duplicate source descriptor");
    keys.add(sourceKey); tracks.add(stream.mediaTrackId); orders.add(stream.order);
    if (stream.focused) focusCount += 1;
    return Object.freeze({
      key: sourceKey,
      ownerParticipantID: key.ownerParticipantId,
      sourceInstanceID: key.sourceInstanceId,
      streamID: stream.id,
      mediaTrackID: stream.mediaTrackId,
      active: stream.active,
      focused: stream.focused,
      appName: stream.appName,
      windowName: stream.windowName,
      width: stream.width,
      height: stream.height,
      sourcePointWidth: stream.sourcePointWidth,
      sourcePointHeight: stream.sourcePointHeight,
      order: stream.order,
    });
  });
  if (focusCount > 1) throw new Error("Multiple focused sources");
  sources.sort((left, right) => left.order - right.order || left.key.localeCompare(right.key));
  return Object.freeze({ revision: value.sourceRevision, membershipRevision: value.membershipRevision, sources });
}

function validOpaqueID(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(value);
}

function validSourceInstanceID(value) {
  if (typeof value !== "string") return false;
  try { decodeBase64URL(value, 16); return true; } catch { return false; }
}

function validText(value, maximumUTF8Bytes) {
  return typeof value === "string" &&
    new TextEncoder().encode(value).length <= maximumUTF8Bytes &&
    !/\p{Cc}/u.test(value);
}

function requireExactKeys(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid source message shape");
  const keys = Object.keys(value);
  if (keys.length !== expected.length || expected.some((key) => !Object.hasOwn(value, key))) {
    throw new Error("Invalid source message shape");
  }
}

function requireAllowedKeys(value, required, optional = []) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid source message shape");
  const allowed = new Set([...required, ...optional]);
  const keys = Object.keys(value);
  if (required.some((key) => !Object.hasOwn(value, key)) || keys.some((key) => !allowed.has(key))) {
    throw new Error("Invalid source message shape");
  }
}

export function emptyWebSourceSnapshot({ sessionId, participantID, sourceRevision }) {
  return {
    version: 4,
    type: "source-snapshot",
    payload: {
      version: 3,
      sessionId,
      membershipRevision: 1,
      ownerParticipantId: participantID,
      sourceRevision,
      sources: [],
    },
  };
}

export function validateSourceCursor(message, expected) {
  requireExactKeys(message, ["version", "type", "payload"]);
  if (message.version !== 4 || message.type !== "source-cursor") throw new Error("Unsupported cursor message");
  const value = message.payload;
  requireAllowedKeys(value, ["sessionId", "participantId", "sourceKey", "streamId", "sequence"], ["position"]);
  requireExactKeys(value.sourceKey, ["ownerParticipantId", "sourceInstanceId"]);
  if (
    value.sessionId !== expected.sessionId ||
    value.participantId !== expected.ownerParticipantID ||
    value.sourceKey.ownerParticipantId !== expected.ownerParticipantID ||
    !validSourceInstanceID(value.sourceKey.sourceInstanceId) ||
    !validOpaqueID(value.streamId) ||
    !Number.isSafeInteger(value.sequence) || value.sequence < 1
  ) throw new Error("Source cursor context mismatch");
  let position = null;
  if (value.position != null) {
    requireExactKeys(value.position, ["x", "y"]);
    if (![value.position.x, value.position.y].every((coordinate) => Number.isFinite(coordinate) && coordinate >= 0 && coordinate <= 1)) {
      throw new Error("Invalid source cursor position");
    }
    position = Object.freeze({ x: value.position.x, y: value.position.y });
  }
  return Object.freeze({
    key: `${expected.ownerParticipantID}:${value.sourceKey.sourceInstanceId}`,
    streamID: value.streamId,
    sequence: value.sequence,
    position,
  });
}

export function nativePanGeometry({ sourceWidth, sourceHeight, viewportWidth, viewportHeight, cursor = null }) {
  if (![sourceWidth, sourceHeight, viewportWidth, viewportHeight].every((value) => Number.isFinite(value) && value > 0)) return null;
  const x = Number.isFinite(cursor?.x) && cursor.x >= 0 && cursor.x <= 1 ? cursor.x : 0.5;
  const y = Number.isFinite(cursor?.y) && cursor.y >= 0 && cursor.y <= 1 ? cursor.y : 0.5;
  const clampAxis = (preferred, content, viewport) => content <= viewport
    ? (viewport - content) / 2
    : Math.max(viewport - content, Math.min(0, preferred));
  return Object.freeze({
    width: sourceWidth,
    height: sourceHeight,
    left: clampAxis(viewportWidth / 2 - x * sourceWidth, sourceWidth, viewportWidth),
    top: clampAxis(viewportHeight / 2 - y * sourceHeight, sourceHeight, viewportHeight),
  });
}

export function participantConnectionState(member, peerState = null) {
  if (member?.isLocal) return { state: "p2p" };
  if (member?.connected === false) return { state: "disconnected" };
  return peerState ?? { state: "connecting" };
}

export function unsupportedEncodingPresentation(peerStates) {
  const failures = [...peerStates.values()].filter((state) => state.details?.unsupportedEncoding);
  if (failures.length === 0) return null;
  const codecs = [...new Set(failures.map((state) => state.details?.codec).filter(Boolean))].sort();
  const suffix = codecs.length === 1 ? `: ${codecs[0]}` : "";
  return Object.freeze({
    title: `Unsupported Encoding${suffix}`,
    message: "Clip will not fall back or create a second encoding. Room membership and compatible participant links continue normally; media on this peer edge may be unavailable.",
  });
}
