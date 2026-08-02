import {
  ClipWebProtocolError,
  decodeBase64URL,
  derivePairContext,
  EncryptedPairChannel,
  exportWebIdentity,
  importWebIdentity,
  makeOpaqueJoinKnock,
  openAdmissionRecord,
  openClipV4Invite,
  createWebIdentity,
  descriptorsEqual,
} from "./clip-room-crypto.js";
import { ClipWebMeshPeer } from "./clip-mesh-peer.js";
import { ClipWebMediaStore } from "./clip-media-store.js";
import { ClipSerialQueue } from "./clip-serial-queue.js";

const MAX_WIRE_BYTES = 262144;
const TERMINAL_STATES = new Set(["ended", "left"]);
const DEFAULT_RECONNECT_ATTEMPTS = 6;
const TAB_CLAIM_WAIT_MS = 75;
const ROOM_SUBPROTOCOL = "clip-native-room-v4";

export class ClipWebReconnectError extends Error {
  constructor(message, retryable) {
    super(message);
    this.name = "ClipWebReconnectError";
    this.retryable = retryable;
  }
}

export class ClipWebActiveTabClaim {
  constructor(storageKey, { channelFactory = defaultChannelFactory, wait = defaultWait } = {}) {
    this.participantID = null;
    this.pendingClaims = new Map();
    this.wait = wait;
    this.channel = channelFactory?.(`clip.webViewer.active.v1.${storageKey}`) ?? null;
    this.receive = (event) => this.receiveMessage(event?.data);
    this.channel?.addEventListener("message", this.receive);
  }

  async activate(participantID, { probe = true } = {}) {
    this.participantID = participantID;
    if (!probe || !this.channel) return false;
    const claimID = randomToken();
    let conflict = false;
    this.pendingClaims.set(claimID, () => { conflict = true; });
    this.channel.postMessage({ type: "identity-probe", claimID, participantID });
    await this.wait(TAB_CLAIM_WAIT_MS);
    this.pendingClaims.delete(claimID);
    return conflict;
  }

  receiveMessage(message) {
    if (!message || typeof message !== "object") return;
    if (message.type === "identity-probe" && this.participantID && message.participantID === this.participantID) {
      this.channel?.postMessage({ type: "identity-occupied", claimID: message.claimID, participantID: message.participantID });
      return;
    }
    if (message.type === "identity-occupied" && message.participantID === this.participantID) {
      this.pendingClaims.get(message.claimID)?.();
    }
  }

  close() {
    this.pendingClaims.clear();
    this.channel?.removeEventListener?.("message", this.receive);
    this.channel?.close();
    this.channel = null;
    this.participantID = null;
  }
}

export class ClipWebRoomSession extends EventTarget {
  constructor({ invite, identity, iceServers, reconnectPolicy = null }) {
    super();
    this.invite = invite;
    this.identity = identity;
    this.iceServers = iceServers;
    this.media = new ClipWebMediaStore(invite.sessionId);
    this.socket = null;
    this.socketGeneration = 0;
    this.joinSequence = 0;
    this.localHandle = null;
    this.reconnectCapability = null;
    this.creatorHandle = null;
    this.rosterRevision = 0;
    this.members = new Map();
    this.peers = new Map();
    this.pendingPairSignals = new Map();
    this.accessWord = null;
    this.state = "idle";
    this.closed = false;
    this.reconnectAttempt = 0;
    this.reconnectTimer = null;
    this.lastRosterJSON = null;
    this.wireQueue = new ClipSerialQueue();
    this.signalingRecoveryRequired = false;
    this.tabClaim = null;
    this.maximumReconnectAttempts = reconnectPolicy?.maximumAttempts ?? DEFAULT_RECONNECT_ATTEMPTS;
    this.reconnectDelay = reconnectPolicy?.delay ?? reconnectDelay;
    this.socketOpenTimeout = reconnectPolicy?.socketOpenTimeout ?? 10000;
  }

  static async bootstrap(url = window.location.href, displayName = "Web Viewer") {
    const invite = await openClipV4Invite(url);
    const storageKey = `clip.webViewer.v4.${invite.roomId}`;
    const { identity, claim } = await resolveBrowserTabIdentity({
      storageKey,
      displayName,
      storage: sessionStorage,
      navigationType: navigationType(),
    });
    let capabilities;
    try {
      capabilities = await fetchCapabilities(invite.serviceEndpoint);
    } catch (error) {
      claim.close();
      throw error;
    }
    const session = new ClipWebRoomSession({ invite, identity, iceServers: capabilities.iceServers });
    session.tabClaim = claim;
    session.storageKey = storageKey;
    try {
      const reconnect = JSON.parse(sessionStorage.getItem(`${storageKey}.reconnect`) ?? "null");
      if (reconnect?.memberHandle && reconnect?.reconnectCapability) {
        decodeBase64URL(reconnect.memberHandle, 16);
        decodeBase64URL(reconnect.reconnectCapability, 32);
        session.localHandle = reconnect.memberHandle;
        session.reconnectCapability = reconnect.reconnectCapability;
      }
    } catch {
      sessionStorage.removeItem(`${storageKey}.reconnect`);
    }
    return session;
  }

  async connect() {
    if (this.closed) throw new Error("Room session is closed");
    this.setState(this.localHandle ? "reconnecting" : "connecting");
    try {
      if (this.localHandle && this.reconnectCapability) {
        this.signalingRecoveryRequired = this.members.size > 1;
        const ticket = await this.obtainReconnectTicket();
        await this.openSocket([ROOM_SUBPROTOCOL, `reconnect.${ticket}`]);
        return;
      }
      this.joinSequence = 0;
      await this.openSocket([ROOM_SUBPROTOCOL]);
    } catch (error) {
      if (isRetryableReconnectError(error)) {
        this.scheduleReconnect(error);
      } else {
        this.setState("reconnect-failed", "Clip could not resume this browser tab. Open the original invite in a new tab to rejoin.");
      }
    }
  }

  async obtainReconnectTicket() {
    let response;
    try {
      response = await fetch(`${this.invite.serviceEndpoint}/api/native/v4/rooms/${this.invite.roomId}/browser-reconnect`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${this.reconnectCapability}`,
        },
        body: JSON.stringify({ memberHandle: this.localHandle }),
        cache: "no-store",
        credentials: "omit",
        referrerPolicy: "no-referrer",
      });
    } catch {
      throw new ClipWebReconnectError("Reconnect service is temporarily unavailable", true);
    }
    if (!response.ok) {
      const retryable = response.status === 408 || response.status === 425 || response.status === 429 || response.status >= 500;
      throw new ClipWebReconnectError("Reconnect credential rejected", retryable);
    }
    let value;
    try {
      value = await response.json();
    } catch {
      throw new ClipWebReconnectError("Reconnect response was interrupted", true);
    }
    if (!value || typeof value.ticket !== "string" || !/^[A-Za-z0-9_-]{20,256}$/u.test(value.ticket)) throw new ClipWebReconnectError("Invalid reconnect ticket", false);
    return value.ticket;
  }

  openSocket(protocols) {
    return new Promise((resolve, reject) => {
      const generation = ++this.socketGeneration;
      const url = new URL(`/api/native/v4/rooms/${this.invite.roomId}/socket`, this.invite.serviceEndpoint);
      url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
      const socket = new WebSocket(url, protocols);
      this.socket = socket;
      let opened = false;
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        callback(value);
      };
      const timeout = setTimeout(() => {
        socket.close();
        finish(reject, new ClipWebReconnectError("Room socket timed out", true));
      }, this.socketOpenTimeout);
      socket.addEventListener("open", () => {
        if (generation !== this.socketGeneration) return;
        if (!isExpectedRoomSubprotocol(socket.protocol)) {
          socket.close(1002, "room subprotocol missing");
          finish(reject, new ClipWebReconnectError("Room service selected an incompatible WebSocket protocol", false));
          return;
        }
        opened = true;
        finish(resolve);
      }, { once: true });
      socket.addEventListener("error", () => {
        if (!opened) finish(reject, new ClipWebReconnectError("Room socket failed", true));
      }, { once: true });
      socket.addEventListener("message", (event) => {
        if (generation !== this.socketGeneration) return;
        void this.wireQueue.enqueue(async () => {
          if (generation !== this.socketGeneration) return;
          await this.receiveWire(event.data);
        }).catch((error) => this.fail(error));
      });
      socket.addEventListener("close", () => {
        if (generation !== this.socketGeneration || this.closed) return;
        this.signalingRecoveryRequired = this.localHandle !== null && this.members.size > 1;
        if (!opened) finish(reject, new ClipWebReconnectError("Room socket closed before opening", true));
        else this.scheduleReconnect();
      });
    });
  }

  async receiveWire(data) {
    if (typeof data !== "string" || new TextEncoder().encode(data).length > MAX_WIRE_BYTES) throw new Error("Invalid room message");
    const message = JSON.parse(data);
    if (!message || message.version !== 4 || typeof message.type !== "string") throw new Error("Invalid room message");
    switch (message.type) {
      case "candidate-opened": {
        requireKeys(message, ["type", "version", "candidateHandle", "roomDescriptor"]);
        decodeBase64URL(message.candidateHandle, 16);
        const creator = await openAdmissionRecord(this.invite, message.roomDescriptor);
        if (creator.descriptor.identity !== this.invite.creatorIdentity) throw new Error("Room creator identity mismatch");
        this.creatorHandle = creator.memberHandle;
        this.joinSequence += 1;
        this.sendWire({
          type: "join-knock", version: 4, sequence: this.joinSequence,
          payload: await makeOpaqueJoinKnock(this.invite, this.identity, this.accessWord),
        });
        this.setState("waiting", "Waiting for the room to admit this browser…");
        break;
      }
      case "deny-candidate":
        this.setState(message.reason?.toLowerCase().includes("access") ? "access-word" : "denied", message.reason || "The room owner denied this request.");
        break;
      case "member-admitted":
        requireKeys(message, ["type", "version", "memberHandle", "roster"], ["reconnectCapability"]);
        this.localHandle = message.memberHandle;
        // Reconnect admission snapshots intentionally omit the capability;
        // keep the credential already restored for this tab.
        this.reconnectCapability = nextReconnectCapability(this.reconnectCapability, message.reconnectCapability);
        if (this.reconnectCapability) {
          try { sessionStorage.setItem(`${this.storageKey}.reconnect`, JSON.stringify({
            memberHandle: this.localHandle,
            reconnectCapability: this.reconnectCapability,
          })); } catch { /* The current socket remains usable without reload persistence. */ }
        }
        await this.applyRoster(message.roster, { recoverInterruptedPeers: this.signalingRecoveryRequired });
        this.signalingRecoveryRequired = false;
        this.reconnectAttempt = 0;
        this.setState("connected");
        break;
      case "roster-snapshot":
        requireKeys(message, ["type", "version", "roster"]);
        await this.applyRoster(message.roster, { recoverInterruptedPeers: this.signalingRecoveryRequired });
        this.signalingRecoveryRequired = false;
        this.reconnectAttempt = 0;
        this.setState("connected");
        break;
      case "pair-signal": await this.receivePairSignal(message); break;
      case "room-ended":
        // Closing peer transports emits media-store changes synchronously.
        // Publish the terminal state last so those cleanup renders cannot
        // replace “Live Share Ended” with the ordinary empty-room message.
        this.close(false);
        this.setState("ended", message.reason || "The Live Share ended.");
        break;
      case "protocol-error": this.receiveProtocolError(message); break;
      default: throw new Error(`Unsupported room message: ${message.type}`);
    }
  }

  async applyRoster(roster, { recoverInterruptedPeers = false } = {}) {
    validateRoster(roster);
    const serialized = JSON.stringify(roster);
    if (roster.revision < this.rosterRevision) return;
    if (roster.revision === this.rosterRevision) {
      if (serialized !== this.lastRosterJSON) throw new Error("Conflicting room roster revision");
      if (recoverInterruptedPeers) await this.recoverInterruptedPeerEdges();
      return;
    }
    const verified = [];
    const participantIDs = new Set();
    const identities = new Set();
    const pairKeys = new Set();
    for (const member of [...roster.members].sort((left, right) => left.handle.localeCompare(right.handle))) {
      const record = await openAdmissionRecord(this.invite, member.descriptor, member.handle);
      const descriptor = record.descriptor;
      if (participantIDs.has(descriptor.participantID) || identities.has(descriptor.identity) || pairKeys.has(descriptor.pairSignalingPublicKey)) {
        throw new Error("Duplicate participant identity in room roster");
      }
      participantIDs.add(descriptor.participantID); identities.add(descriptor.identity); pairKeys.add(descriptor.pairSignalingPublicKey);
      verified.push({ handle: member.handle, connected: member.connected, descriptor });
    }
    const creator = verified.find((member) => member.handle === roster.creatorHandle);
    if (!creator || creator.descriptor.identity !== this.invite.creatorIdentity) throw new Error("Room creator changed unexpectedly");
    const local = verified.find((member) => member.handle === this.localHandle);
    if (!local || !descriptorsEqual(local.descriptor, this.identity.descriptor)) throw new Error("The room roster does not contain this browser identity");

    const nextMembers = new Map(verified.map((member) => [member.handle, member]));
    this.creatorHandle = roster.creatorHandle;
    this.rosterRevision = roster.revision;
    this.lastRosterJSON = serialized;
    this.members = nextMembers;
    this.media.setParticipants(verified, roster.creatorHandle, this.localHandle);

    await this.reconcilePeerTopology(verified, { recoverInterruptedPeers });
    this.dispatchEvent(new CustomEvent("roster", { detail: { members: verified, creatorHandle: roster.creatorHandle } }));
  }

  async reconcilePeerTopology(members, { recoverInterruptedPeers = false, updateRetainedPeers = true } = {}) {
    const nextMembers = new Map(members.map((member) => [member.handle, member]));
    for (const [handle, peer] of this.peers) {
      const member = nextMembers.get(handle);
      if (!member || !member.connected) {
        peer.close(false);
        this.peers.delete(handle);
      }
    }
    for (const member of members) {
      if (member.handle === this.localHandle || !member.connected) continue;
      let peer = this.peers.get(member.handle);
      if (peer && recoverInterruptedPeers && peer.needsRecreationAfterSignalingReconnect()) {
        peer.close(false);
        this.peers.delete(member.handle);
        peer = null;
      }
      if (!peer) {
        await this.startPeer(member);
      } else if (updateRetainedPeers) {
        await peer.updateRosterRevision(this.rosterRevision);
      }
    }
  }

  async startPeer(member) {
    const peer = await this.createPeer(member);
    this.peers.set(member.handle, peer);
    try {
      await peer.start();
    } catch (error) {
      this.media.setPeerState(peer.remoteParticipantID, "failed", { message: String(error?.message ?? error) });
    }
    const queued = this.pendingPairSignals.get(member.handle) ?? [];
    this.pendingPairSignals.delete(member.handle);
    for (const signal of queued) await this.openPairSignal(peer, signal);
    return peer;
  }

  async recoverInterruptedPeerEdges() {
    await this.reconcilePeerTopology([...this.members.values()], {
      recoverInterruptedPeers: true,
      updateRetainedPeers: false,
    });
  }

  async createPeer(remoteMember) {
    const context = await derivePairContext(
      this.invite,
      this.localHandle,
      this.identity.descriptor.participantID,
      remoteMember.handle,
      remoteMember.descriptor.participantID,
    );
    const persisted = this.loadPairState(context.pairId);
    const pairChannel = await EncryptedPairChannel.create({
      context,
      localIdentity: this.identity,
      remoteDescriptor: remoteMember.descriptor,
      sequenceState: persisted,
    });
    return new ClipWebMeshPeer({
      context,
      remoteMember,
      pairChannel,
      iceServers: this.iceServers,
      mediaStore: this.media,
      sendSignal: (envelope) => this.sendWire(envelope),
      rosterRevision: this.rosterRevision,
      localParticipantID: this.identity.descriptor.participantID,
      sessionId: this.invite.sessionId,
      initialState: persisted,
      pairStateDidChange: (state) => this.savePairState(context.pairId, state),
    });
  }

  async receivePairSignal(message) {
    requireKeys(message, ["type", "version", "sequence", "payload", "from", "to", "pairId"]);
    if (message.to !== this.localHandle || typeof message.from !== "string") throw new Error("Pair signal route mismatch");
    let peer = this.peers.get(message.from);
    if (!peer) {
      const queued = this.pendingPairSignals.get(message.from) ?? [];
      if (queued.length >= 128) throw new Error("Too many pending pair signals");
      queued.push(message);
      this.pendingPairSignals.set(message.from, queued);
      return;
    }
    await this.openPairSignal(peer, message);
  }

  async openPairSignal(peer, message) {
    try {
      await peer.receiveEnvelope(message);
    } catch (error) {
      // Pair signaling is end-to-end authenticated. A malformed payload is a
      // fault on that one edge and must not tear down the room or other peers.
      peer.isolateFailure(error);
    }
  }

  loadPairState(pairID) {
    if (!this.storageKey) return null;
    try {
      const value = JSON.parse(sessionStorage.getItem(`${this.storageKey}.pair.${pairID}`) ?? "null");
      if (!value || value.epoch !== 1 || !["inbound", "outbound", "sourceRevision"].every((key) => Number.isSafeInteger(value[key]) && value[key] >= 0)) return null;
      return value;
    } catch { return null; }
  }

  savePairState(pairID, state) {
    if (!this.storageKey) return;
    try { sessionStorage.setItem(`${this.storageKey}.pair.${pairID}`, JSON.stringify(state)); } catch { /* Keep the live room usable when storage is unavailable. */ }
  }

  receiveProtocolError(message) {
    const code = typeof message.code === "string" ? message.code : "protocol_error";
    if (message.pairId && message.to) {
      const peer = this.peers.get(message.to);
      if (peer) {
        const text = message.message || code;
        const unsupportedEncoding = /codec|encoding|sdp|rtcp\s*mux/iu.test(text);
        const codec = extractCodecName(text);
        this.media.setPeerState(
          peer.remoteParticipantID,
          unsupportedEncoding ? "connected" : "failed",
          { message: text, unsupportedEncoding, codec },
        );
      }
      return;
    }
    if (code === "room_full") this.setState("full", "This room already has four participants.");
    else if (code === "creator_offline") this.setState("waiting", "The room creator is reconnecting…");
    else this.setState("error", message.message || code);
  }

  async retryAdmission(accessWord) {
    this.accessWord = accessWord;
    this.localHandle = null;
    this.reconnectCapability = null;
    this.joinSequence = 0;
    this.socketGeneration += 1;
    this.socket?.close(1000, "retry admission");
    this.setState("waiting", "Checking the Access Word…");
    await this.connect();
  }

  sendWire(message) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error("Room connection is unavailable");
    this.socket.send(JSON.stringify(message));
  }

  scheduleReconnect() {
    if (!shouldReconnectRoomState(this.state, this.closed)) return;
    if (this.reconnectTimer !== null) return;
    if (this.reconnectAttempt >= this.maximumReconnectAttempts) {
      this.setState("reconnect-failed", "Clip could not resume this browser tab after several attempts. Open the invite again to rejoin.");
      return;
    }
    this.setState("reconnecting", "Reconnecting to the room…");
    const delay = this.reconnectDelay(this.reconnectAttempt);
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connect().catch((error) => this.fail(error));
    }, delay);
  }

  setState(state, message = null) {
    if ((this.closed || TERMINAL_STATES.has(this.state)) && !TERMINAL_STATES.has(state)) return false;
    if (TERMINAL_STATES.has(this.state) && this.state !== state) return false;
    this.state = state;
    this.dispatchEvent(new CustomEvent("state", { detail: { state, message } }));
    return true;
  }

  fail(error) {
    const message = error instanceof ClipWebProtocolError ? error.message : String(error?.message ?? error);
    this.setState("error", message);
  }

  close(sendLeave = true) {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.reconnectTimer);
    for (const peer of this.peers.values()) peer.close(false);
    this.peers.clear();
    if (sendLeave && this.socket?.readyState === WebSocket.OPEN) {
      try { this.sendWire({ type: "leave-room", version: 4 }); } catch { /* Best effort. */ }
    }
    this.socketGeneration += 1;
    this.socket?.close(1000, "viewer left");
    this.tabClaim?.close();
    if (this.storageKey) {
      try {
        for (let index = sessionStorage.length - 1; index >= 0; index -= 1) {
          const key = sessionStorage.key(index);
          if (key?.startsWith(`${this.storageKey}.pair.`)) sessionStorage.removeItem(key);
        }
        sessionStorage.removeItem(`${this.storageKey}.reconnect`);
        sessionStorage.removeItem(`${this.storageKey}.identity`);
      } catch { /* Explicit leave still closes every live transport. */ }
    }
    if (sendLeave) this.setState("left", "This browser is no longer connected.");
  }
}

export function shouldReconnectRoomState(state, closed = false) {
  return !closed && !["ended", "left", "denied", "access-word", "full", "reconnect-failed"].includes(state);
}

export function isExpectedRoomSubprotocol(value) {
  return value === ROOM_SUBPROTOCOL;
}

export function nextReconnectCapability(current, incoming) {
  return incoming === undefined ? current : incoming;
}

export function reconnectDelay(attempt) {
  return Math.min(10000, 500 * (2 ** Math.min(attempt, 5)));
}

export function isRetryableReconnectError(error) {
  return error instanceof ClipWebReconnectError && error.retryable === true;
}

export async function resolveBrowserTabIdentity({
  storageKey,
  displayName,
  storage,
  navigationType = "navigate",
  channelFactory = defaultChannelFactory,
  wait = defaultWait,
}) {
  let identity = null;
  let restored = false;
  try {
    const stored = storage.getItem(`${storageKey}.identity`);
    identity = stored ? await importWebIdentity(JSON.parse(stored)) : null;
    restored = identity !== null;
  } catch { identity = null; }
  const claim = new ClipWebActiveTabClaim(storageKey, { channelFactory, wait });
  if (identity) {
    const collision = await claim.activate(identity.descriptor.participantID, { probe: navigationType !== "reload" });
    if (collision) {
      clearRoomStorage(storage, storageKey);
      identity = null;
      restored = false;
    }
  }
  if (!identity) {
    identity = await createWebIdentity(displayName);
    try { storage.setItem(`${storageKey}.identity`, JSON.stringify(await exportWebIdentity(identity))); } catch { /* Storage is optional for this live tab. */ }
    await claim.activate(identity.descriptor.participantID, { probe: false });
  }
  return { identity, claim, restored };
}

function clearRoomStorage(storage, storageKey) {
  try {
    for (let index = storage.length - 1; index >= 0; index -= 1) {
      const key = storage.key(index);
      if (key?.startsWith(`${storageKey}.pair.`)) storage.removeItem(key);
    }
    storage.removeItem(`${storageKey}.reconnect`);
    storage.removeItem(`${storageKey}.identity`);
  } catch { /* A fresh in-memory identity still prevents duplicate membership. */ }
}

function navigationType() {
  try { return performance.getEntriesByType("navigation")[0]?.type ?? "navigate"; } catch { return "navigate"; }
}

function defaultChannelFactory(name) {
  return typeof BroadcastChannel === "function" ? new BroadcastChannel(name) : null;
}

function defaultWait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function randomToken() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function extractCodecName(text) {
  return /\b(AV1|VP9|VP8|H\.?264|HEVC)\b/iu.exec(text)?.[1]?.toUpperCase().replace(".", "") ?? null;
}

async function fetchCapabilities(endpoint) {
  const response = await fetch(`${endpoint}/.well-known/clip-native-rendezvous`, { cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" });
  if (!response.ok) throw new Error("Clip room service is unavailable");
  const value = await response.json();
  if (value?.protocol !== "clip-native-room" || value?.apiVersion !== 4 || value?.messageVersion !== 4 || !Array.isArray(value.iceServers)) {
    throw new Error("Clip room service does not support browser mesh participants");
  }
  return { iceServers: value.iceServers.map((entry) => ({ urls: entry.urls, username: entry.username, credential: entry.credential })) };
}

function requireKeys(object, required, optional = []) {
  const actual = new Set(Object.keys(object));
  const allowed = new Set([...required, ...optional]);
  if (!required.every((key) => actual.has(key)) || [...actual].some((key) => !allowed.has(key))) throw new Error("Invalid room message shape");
}

function validateRoster(roster) {
  if (!roster || !Number.isSafeInteger(roster.revision) || roster.revision < 1 || typeof roster.creatorHandle !== "string" || !Array.isArray(roster.members) || roster.members.length < 1 || roster.members.length > 4) {
    throw new Error("Invalid room roster");
  }
  decodeBase64URL(roster.creatorHandle, 16);
  const handles = new Set();
  for (const member of roster.members) {
    requireKeys(member, ["handle", "descriptor", "connected"]);
    decodeBase64URL(member.handle, 16);
    if (handles.has(member.handle) || typeof member.descriptor !== "string" || typeof member.connected !== "boolean") throw new Error("Invalid room roster member");
    handles.add(member.handle);
  }
  if (!handles.has(roster.creatorHandle)) throw new Error("Room creator is missing");
}
