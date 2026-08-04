import { emptyWebSourceSnapshot, validateSourceSnapshot } from "./clip-viewer-state.js";
import { ClipSerialQueue } from "./clip-serial-queue.js";
import { configureWebReceiverLatency } from "./clip-web-receiver.js";

const CONTROL_LABEL = "clip-native-control-v3";
const MAX_CONTROL_BYTES = 196400;
const MAX_REMOTE_ICE_CANDIDATES = 256;
export const PAIR_EPOCH = 1;

export class ClipWebMeshPeer extends EventTarget {
  constructor({
    context,
    remoteMember,
    pairChannel,
    iceServers,
    mediaStore,
    sendSignal,
    rosterRevision,
    localParticipantID,
    sessionId,
    initialState = null,
    pairStateDidChange = null,
  }) {
    super();
    this.context = context;
    this.remoteMember = remoteMember;
    this.pairChannel = pairChannel;
    this.mediaStore = mediaStore;
    this.sendSignal = sendSignal;
    // Native media membership is deliberately independent from the server
    // roster revision. The current media contract has one room-lifetime
    // membership generation, even when participants join later.
    this.rosterRevision = 1;
    this.localParticipantID = localParticipantID;
    this.sessionId = sessionId;
    this.resumed = initialState !== null;
    // Native v4 assigns one fixed signaling epoch to a peer-pair lifetime.
    // ICE recovery renegotiates within epoch 1; native peers intentionally
    // discard offers, answers, and candidates carrying any other epoch.
    this.epoch = PAIR_EPOCH;
    this.sourceRevision = Number.isSafeInteger(initialState?.sourceRevision) && initialState.sourceRevision >= 0 ? initialState.sourceRevision : 0;
    this.pairStateDidChange = pairStateDidChange;
    this.pendingCandidates = [];
    this.receivedCandidateCount = 0;
    this.closed = false;
    this.controlChannel = null;
    this.remoteTrackIDsByMID = new Map();
    this.outboundSignalQueue = new ClipSerialQueue();
    this.inboundSignalQueue = new ClipSerialQueue();
    this.recoveryRequested = false;
    this.signalingInterrupted = false;
    this.isOfferer = context.initialOfferer === context.localHandle;
    this.connection = new RTCPeerConnection({ iceServers, bundlePolicy: "max-bundle" });
    this.configureConnection();
  }

  configureConnection() {
    const pc = this.connection;
    pc.addEventListener("icecandidate", (event) => {
      if (!event.candidate || this.closed) return;
      void this.signal({
        type: "ice-candidate",
        epoch: this.epoch,
        candidate: event.candidate.candidate,
        mediaId: event.candidate.sdpMid ?? null,
        mediaLineIndex: event.candidate.sdpMLineIndex ?? null,
      }).catch(() => { /* The signaling reconnect path recreates interrupted edges. */ });
    });
    pc.addEventListener("connectionstatechange", () => {
      if (this.closed) return;
      const state = pc.connectionState;
      this.mediaStore.setPeerState(this.remoteParticipantID, normalizeConnectionState(state));
      if (state === "connected") this.recoveryRequested = false;
      if (state === "failed") {
        if (this.isOfferer) void this.restartICE().catch(() => {});
        else void this.requestPeerICERestart().catch(() => {});
      }
    });
    pc.addEventListener("track", (event) => {
      if (this.closed) return;
      if (this.remoteIsReceiveOnlyWebViewer) {
        try { event.track.stop(); } catch { /* Best-effort disposal of a forbidden remote track. */ }
        this.rejectRemoteWebPublishing("A receive-only Web participant tried to publish media.");
        return;
      }
      const advertisedTrackID = this.remoteTrackIDsByMID.get(event.transceiver?.mid) ?? event.track.id;
      configureWebReceiverLatency(event.receiver, event.track.kind);
      if (event.track.kind === "video") this.mediaStore.setVideoTrack(this.remoteParticipantID, event.track, advertisedTrackID);
      if (event.track.kind === "audio") {
        this.mediaStore.setAudioTrack(this.remoteParticipantID, event.track);
      }
    });
    pc.addEventListener("datachannel", (event) => {
      if (this.closed) event.channel.close();
      else this.acceptControlChannel(event.channel);
    });
  }

  get remoteParticipantID() { return this.remoteMember.descriptor.participantID; }

  get remoteIsReceiveOnlyWebViewer() {
    const descriptor = this.remoteMember.descriptor;
    return descriptor.clientKind === "webViewer" && descriptor.capabilityProfile === "webViewerV1";
  }

  async start() {
    this.mediaStore.setPeerState(this.remoteParticipantID, "connecting");
    if (!this.isOfferer) {
      // A restored answerer owns a new RTCPeerConnection while the canonical
      // offerer can still own the prior connection's ICE credentials. A plain
      // renegotiation would reuse those credentials and can never attach the
      // offerer's old transport to this replacement peer. Ask the permanent
      // offerer to restart ICE explicitly; this preserves deterministic offer
      // ownership while gathering a fresh candidate generation on both ends.
      if (this.resumed) await this.requestPeerICERestart();
      return;
    }
    for (let index = 0; index < 4; index += 1) this.connection.addTransceiver("video", { direction: "recvonly" });
    this.connection.addTransceiver("audio", { direction: "recvonly" });
    this.acceptControlChannel(this.connection.createDataChannel(CONTROL_LABEL, { ordered: true }));
    await this.makeOffer(false);
  }

  async makeOffer(iceRestart) {
    if (this.closed) return;
    const offer = await this.connection.createOffer({ iceRestart });
    await this.connection.setLocalDescription(offer);
    this.persistState();
    await this.signal({ type: "offer", epoch: this.epoch, sdp: this.connection.localDescription.sdp });
  }

  async restartICE() {
    if (this.closed || !this.isOfferer || this.connection.signalingState !== "stable") return;
    this.connection.restartIce();
    await this.makeOffer(true);
  }

  async requestPeerICERestart() {
    if (this.closed || this.isOfferer || this.recoveryRequested) return;
    this.recoveryRequested = true;
    try {
      await this.signal({ type: "ice-restart", epoch: PAIR_EPOCH });
    } catch (error) {
      // A failed room-socket write must be retryable after signaling resumes.
      // The replacement peer has not made progress until the remote offerer
      // receives this request, so do not leave the one-shot gate latched.
      this.recoveryRequested = false;
      throw error;
    }
  }

  applyExactVideoCodec(codec) {
    const normalizedCodec = String(codec).toLowerCase();
    const capabilities = globalThis.RTCRtpReceiver?.getCapabilities?.("video")?.codecs ?? [];
    const exactPreferences = capabilities.filter(
      (entry) => entry.mimeType?.split("/")[1]?.toLowerCase() === normalizedCodec,
    );
    if (exactPreferences.length === 0) {
      // A Web edge is deliberately exact-only. Do not substitute another
      // codec or create a second encoder: the next offer/answer rejects video
      // and the viewer explains that the selected encoding is unsupported.
      this.mediaStore.setPeerState(this.remoteParticipantID, "connected", {
        unsupportedEncoding: true,
        codec: normalizedCodec.toUpperCase(),
      });
      return false;
    }
    for (const transceiver of this.connection.getTransceivers()) {
      const kind = transceiver.receiver?.track?.kind ?? transceiver.sender?.track?.kind;
      if (kind === "video") transceiver.setCodecPreferences(exactPreferences);
    }
    this.mediaStore.clearUnsupportedEncoding?.(this.remoteParticipantID);
    return true;
  }

  async receiveSignal(payload) {
    if (this.closed) return;
    validatePairPayload(payload);
    if (payload.epoch !== undefined && payload.epoch !== PAIR_EPOCH) return;
    switch (payload.type) {
      case "offer": {
        if (this.isOfferer) throw new Error("Unexpected pair offer from deterministic answerer");
        this.recoveryRequested = false;
        this.remoteTrackIDsByMID = parseRemoteTrackBindings(payload.sdp);
        const offeredCodec = firstOfferedVideoCodec(payload.sdp);
        const signalCodec = exactCodecSignalValue(offeredCodec);
        if (signalCodec && !browserSupportsCodec(signalCodec)) {
          await this.rejectOfferedCodec(signalCodec);
          return;
        }
        try {
          await this.connection.setRemoteDescription({ type: "offer", sdp: payload.sdp });
          this.mediaStore.clearUnsupportedEncoding?.(this.remoteParticipantID);
          this.reconcileRemoteReceivers();
        } catch (error) {
          if (signalCodec) await this.rejectOfferedCodec(signalCodec, error);
          else this.mediaStore.setPeerState(this.remoteParticipantID, "connected", { unsupportedEncoding: true, codec: offeredCodec, message: String(error) });
          return;
        }
        for (const transceiver of this.connection.getTransceivers()) {
          if (transceiver.receiver.track?.kind === "video" || transceiver.receiver.track?.kind === "audio") {
            try { transceiver.direction = "recvonly"; } catch { /* The offered m-line can already be rejected. */ }
          }
        }
        await this.flushCandidates();
        let answer;
        try {
          answer = await this.connection.createAnswer();
          await this.connection.setLocalDescription(answer);
        } catch (error) {
          this.mediaStore.setPeerState(this.remoteParticipantID, "connected", { unsupportedEncoding: true, codec: offeredCodec, message: String(error) });
          return;
        }
        this.detectUnsupportedEncoding(this.connection.localDescription.sdp, offeredCodec);
        await this.signal({ type: "answer", epoch: this.epoch, sdp: this.connection.localDescription.sdp });
        break;
      }
      case "answer":
        if (!this.isOfferer) throw new Error("Unexpected pair answer from deterministic offerer");
        if (payload.epoch !== this.epoch) return;
        this.remoteTrackIDsByMID = parseRemoteTrackBindings(payload.sdp);
        try {
          await this.connection.setRemoteDescription({ type: "answer", sdp: payload.sdp });
          this.mediaStore.clearUnsupportedEncoding?.(this.remoteParticipantID);
          this.reconcileRemoteReceivers();
        } catch (error) {
          this.mediaStore.setPeerState(this.remoteParticipantID, "connected", { unsupportedEncoding: true, message: String(error) });
          return;
        }
        this.detectUnsupportedEncoding(payload.sdp, firstOfferedVideoCodec(payload.sdp));
        await this.flushCandidates();
        break;
      case "ice-candidate": {
        if (payload.epoch !== this.epoch) return;
        this.receivedCandidateCount += 1;
        if (this.receivedCandidateCount > MAX_REMOTE_ICE_CANDIDATES) {
          throw new Error(`The peer exceeded ${MAX_REMOTE_ICE_CANDIDATES} ICE candidates.`);
        }
        const candidate = {
          candidate: payload.candidate,
          sdpMid: payload.mediaId ?? null,
          sdpMLineIndex: payload.mediaLineIndex ?? null,
        };
        if (this.connection.remoteDescription) await this.connection.addIceCandidate(candidate);
        else this.pendingCandidates.push(candidate);
        break;
      }
      case "ice-restart":
      case "renegotiation-request":
        if (this.isOfferer) await this.restartICE();
        break;
      case "codec-renegotiation-request":
        if (!this.isOfferer || this.remoteIsReceiveOnlyWebViewer) {
          throw new Error("Unexpected codec request from deterministic answerer");
        }
        if (this.connection.signalingState !== "stable") {
          throw new Error("Cannot change codec while pair signaling is unstable");
        }
        if (!this.applyExactVideoCodec(payload.codec)) {
          await this.signal({
            type: "codec-renegotiation-rejected",
            epoch: this.epoch,
            codec: payload.codec,
          });
          break;
        }
        await this.makeOffer(false);
        break;
      case "codec-renegotiation-rejected":
        throw new Error("A receive-only Web viewer cannot publish video codec changes");
      case "close": this.close(false); break;
      default: throw new Error("Unsupported pair signal");
    }
  }

  detectUnsupportedEncoding(sdp, codec = null) {
    const videoLines = String(sdp).split(/\r?\n/u).filter((line) => line.startsWith("m=video "));
    if (videoLines.length > 0 && videoLines.every((line) => /^m=video 0\s/u.test(line))) {
      this.mediaStore.setPeerState(this.remoteParticipantID, "connected", { unsupportedEncoding: true, codec });
    }
  }

  async rejectOfferedCodec(codec, error = null) {
    const normalizedCodec = exactCodecSignalValue(codec);
    if (!normalizedCodec) throw new Error("The peer offered an unknown video codec");
    this.mediaStore.setPeerState(this.remoteParticipantID, "connected", {
      unsupportedEncoding: true,
      codec: normalizedCodec.toUpperCase(),
      ...(error ? { message: String(error) } : {}),
    });
    await this.signal({
      type: "codec-renegotiation-rejected",
      epoch: this.epoch,
      codec: normalizedCodec,
    });
  }

  reconcileRemoteReceivers() {
    // A Web-Web connection keeps the ordered control channel so both members
    // remain first-class mesh participants, but webViewerV1 is receive-only.
    // RTCRtpReceiver exposes placeholder tracks for inactive/send-only m-lines
    // in some browsers, so never surface receiver tracks for a Web peer here;
    // an actual forbidden publication is caught by the `track` event above.
    if (this.remoteIsReceiveOnlyWebViewer) return;
    for (const transceiver of this.connection.getTransceivers()) {
      const track = transceiver.receiver?.track;
      if (!track || track.readyState === "ended") continue;
      const advertisedTrackID = this.remoteTrackIDsByMID.get(transceiver.mid) ?? track.id;
      if (track.kind === "video") this.mediaStore.setVideoTrack(this.remoteParticipantID, track, advertisedTrackID);
      if (track.kind === "audio") this.mediaStore.setAudioTrack(this.remoteParticipantID, track);
    }
  }

  async flushCandidates() {
    const candidates = this.pendingCandidates.splice(0);
    for (const candidate of candidates) await this.connection.addIceCandidate(candidate);
  }

  async signal(payload, { sendWhenClosing = false } = {}) {
    if (this.closed && !sendWhenClosing) return;
    return this.outboundSignalQueue.enqueue(async () => {
      if (this.closed && !sendWhenClosing) return;
      const envelope = await this.pairChannel.seal(payload);
      this.persistState();
      try {
        await this.sendSignal(envelope);
      } catch (error) {
        this.signalingInterrupted = true;
        throw error;
      }
    });
  }

  async receiveEnvelope(envelope) {
    return this.inboundSignalQueue.enqueue(async () => {
      if (this.closed) return;
      const payload = await this.pairChannel.open(envelope);
      this.persistState();
      await this.receiveSignal(payload);
    });
  }

  isolateFailure(error) {
    if (this.closed) return;
    const message = String(error?.message ?? error);
    this.mediaStore.setPeerState(this.remoteParticipantID, "failed", { message });
    this.close(false);
  }

  acceptControlChannel(channel) {
    const reliable = channel.ordered === true && channel.maxRetransmits == null && channel.maxPacketLifeTime == null;
    if (this.closed || channel.label !== CONTROL_LABEL || !reliable || this.controlChannel) {
      channel.close();
      return;
    }
    this.controlChannel = channel;
    channel.binaryType = "arraybuffer";
    channel.addEventListener("open", () => void this.sendEmptySnapshot().catch(() => {}));
    channel.addEventListener("message", (event) => this.receiveControl(event.data));
    channel.addEventListener("close", () => {
      if (this.controlChannel === channel) this.controlChannel = null;
    });
  }

  receiveControl(data) {
    if (this.closed) return;
    let text;
    if (typeof data === "string") text = data;
    else if (data instanceof ArrayBuffer) text = new TextDecoder("utf-8", { fatal: true }).decode(data);
    else return;
    if (new TextEncoder().encode(text).length > MAX_CONTROL_BYTES) return;
    let message;
    try { message = JSON.parse(text); } catch { return; }
    if (message?.version !== 4 || typeof message.type !== "string") return;
    if (this.remoteIsReceiveOnlyWebViewer) {
      if (message.type === "source-snapshot") {
        try {
          const snapshot = validateSourceSnapshot(message, {
            sessionId: this.sessionId,
            ownerParticipantID: this.remoteParticipantID,
          });
          if (snapshot.sources.length !== 0) {
            this.rejectRemoteWebPublishing("A receive-only Web participant advertised shared sources.");
            return;
          }
          // The honest empty snapshot is part of the common native control
          // contract and keeps browser-browser edges symmetric and observable.
          this.mediaStore.applySourceSnapshot(this.remoteParticipantID, message);
        } catch (error) {
          this.rejectRemoteWebPublishing(error);
        }
        return;
      }
      if (["source-cursor", "collaboration", "friendship"].includes(message.type)) {
        this.rejectRemoteWebPublishing(`A receive-only Web participant sent ${message.type} data.`);
      }
      return;
    }
    if (message.type === "source-snapshot") {
      try { this.mediaStore.applySourceSnapshot(this.remoteParticipantID, message); } catch { /* Invalid peer metadata is isolated to that edge. */ }
    }
    // Source cursor is useful only for native cursor-follow panning. The first
    // receive-only web profile intentionally has no collaboration renderer.
    if (message.type === "source-cursor") {
      try { this.mediaStore.applySourceCursor(this.remoteParticipantID, message); } catch { /* Invalid cursor metadata is isolated to that edge. */ }
    }
  }

  rejectRemoteWebPublishing(reason) {
    if (this.closed) return;
    const message = String(reason?.message ?? reason);
    this.mediaStore.setPeerState(this.remoteParticipantID, "failed", {
      message,
      capabilityViolation: true,
    });
    // Authentication and room membership remain intact; only the offending
    // P2P edge is retired, so unrelated native/browser links keep running.
    this.close(false);
  }

  async updateRosterRevision(rosterRevision) {
    // Server roster changes do not advance native media membership.
    this.rosterRevision = 1;
    await this.sendEmptySnapshot();
  }

  async sendEmptySnapshot() {
    const channel = this.controlChannel;
    if (!channel || channel.readyState !== "open") return;
    this.sourceRevision += 1;
    channel.send(JSON.stringify(emptyWebSourceSnapshot({
      sessionId: this.sessionId,
      membershipRevision: this.rosterRevision,
      participantID: this.localParticipantID,
      sourceRevision: this.sourceRevision,
    })));
    this.persistState();
  }

  persistState() {
    this.pairStateDidChange?.({
      inbound: this.pairChannel.inboundSequence,
      outbound: this.pairChannel.outboundSequence,
      epoch: this.epoch,
      sourceRevision: this.sourceRevision,
    });
  }

  needsRecreationAfterSignalingReconnect() {
    return this.closed || this.signalingInterrupted || this.connection.connectionState !== "connected" || this.connection.signalingState !== "stable";
  }

  close(sendClose = true) {
    if (this.closed) return;
    if (sendClose) void this.signal({ type: "close" }, { sendWhenClosing: true }).catch(() => {});
    this.closed = true;
    if (this.controlChannel) this.controlChannel.close();
    this.connection.close();
    this.mediaStore.clearRemoteMedia(this.remoteParticipantID);
  }
}

function normalizeConnectionState(state) {
  switch (state) {
    case "connected": return "p2p";
    case "failed": return "failed";
    case "disconnected": return "reconnecting";
    case "closed": return "closed";
    default: return "connecting";
  }
}

export function parseRemoteTrackBindings(sdp) {
  const bindings = new Map();
  let kind = null;
  let mid = null;
  let trackID = null;
  const commit = () => {
    if ((kind === "video" || kind === "audio") && mid != null && trackID) bindings.set(mid, trackID);
  };
  for (const line of String(sdp ?? "").split(/\r?\n/u)) {
    if (line.startsWith("m=")) {
      commit();
      kind = /^m=(video|audio)\s/u.exec(line)?.[1] ?? null;
      mid = null;
      trackID = null;
    } else if (line.startsWith("a=mid:")) {
      mid = line.slice(6).trim();
    } else if (line.startsWith("a=msid:")) {
      const fields = line.slice(7).trim().split(/\s+/u);
      if (fields.length >= 2) trackID = fields[1];
    }
  }
  commit();
  return bindings;
}

export function firstOfferedVideoCodec(sdp) {
  const lines = String(sdp ?? "").split(/\r?\n/u);
  const start = lines.findIndex((line) => line.startsWith("m=video "));
  if (start < 0) return null;
  const payloads = new Set(lines[start].trim().split(/\s+/u).slice(3));
  for (let index = start + 1; index < lines.length && !lines[index].startsWith("m="); index += 1) {
    const match = /^a=rtpmap:(\d+)\s+([^/\s]+)/iu.exec(lines[index]);
    if (match && payloads.has(match[1]) && !/^(rtx|red|ulpfec|flexfec)$/iu.test(match[2])) return match[2].toUpperCase();
  }
  return null;
}

export function browserSupportsCodec(codec) {
  const capabilities = globalThis.RTCRtpReceiver?.getCapabilities?.("video")?.codecs ?? [];
  return capabilities.some((entry) => entry.mimeType?.split("/")[1]?.toUpperCase() === codec.toUpperCase());
}

function exactCodecSignalValue(codec) {
  const normalized = String(codec ?? "").toLowerCase();
  return ["h264", "vp8", "vp9", "av1"].includes(normalized) ? normalized : null;
}

export function validatePairPayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload) || typeof payload.type !== "string") {
    throw new Error("Invalid pair signal payload");
  }
  const textBytes = (value) => typeof value === "string" ? new TextEncoder().encode(value).length : -1;
  const exact = (required, optional = []) => {
    const actual = Object.keys(payload);
    const allowed = new Set([...required, ...optional]);
    if (required.some((key) => !Object.hasOwn(payload, key)) || actual.some((key) => !allowed.has(key))) {
      throw new Error("Invalid pair signal payload shape");
    }
  };
  switch (payload.type) {
    case "offer": case "answer":
      exact(["type", "epoch", "sdp"]);
      if (payload.epoch !== PAIR_EPOCH || textBytes(payload.sdp) < 1 || textBytes(payload.sdp) > 64 * 1024) throw new Error("Invalid pair SDP");
      break;
    case "ice-candidate":
      exact(["type", "epoch", "candidate"], ["mediaId", "mediaLineIndex"]);
      if (payload.epoch !== PAIR_EPOCH || textBytes(payload.candidate) < 0 || textBytes(payload.candidate) > 4 * 1024) throw new Error("Invalid ICE candidate");
      if (payload.mediaId !== undefined && payload.mediaId !== null && (textBytes(payload.mediaId) < 0 || textBytes(payload.mediaId) > 256)) throw new Error("Invalid ICE media ID");
      if (payload.mediaLineIndex !== undefined && payload.mediaLineIndex !== null && (!Number.isSafeInteger(payload.mediaLineIndex) || payload.mediaLineIndex < 0 || payload.mediaLineIndex > 0xffffffff)) throw new Error("Invalid ICE media line index");
      break;
    case "ice-restart": case "renegotiation-request":
      exact(["type", "epoch"]);
      if (payload.epoch !== PAIR_EPOCH) throw new Error("Invalid pair epoch");
      break;
    case "codec-renegotiation-request": case "codec-renegotiation-rejected":
      exact(["type", "epoch", "codec"]);
      if (payload.epoch !== PAIR_EPOCH || !["h264", "vp8", "vp9", "av1"].includes(payload.codec)) {
        throw new Error("Invalid pair codec request");
      }
      break;
    case "close":
      exact(["type"]);
      break;
    default: throw new Error("Unsupported pair signal payload");
  }
  return payload;
}
