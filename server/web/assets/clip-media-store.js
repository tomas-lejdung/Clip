import {
  chooseFollowSource,
  reconcileManualSelection,
  reconcileFollowState,
  validateSourceSnapshot,
  validateSourceCursor,
} from "./clip-viewer-state.js";

export class ClipWebMediaStore extends EventTarget {
  constructor(sessionId) {
    super();
    this.sessionId = sessionId;
    this.participants = new Map();
    this.participantOrder = [];
    this.sourcesByParticipant = new Map();
    this.videoTracks = new Map();
    this.audioTracks = new Map();
    this.peerStates = new Map();
    this.sourceCursors = new Map();
    this.nativePanBySource = new Map();
    this.followEnabled = true;
    this.followParticipantID = null;
    this.selectedSourceKey = null;
    this.layout = "focus";
    this.scaleMode = "native";
  }

  setParticipants(members, creatorHandle, localHandle) {
    const prior = this.participants;
    this.participants = new Map(members.map((member) => [member.descriptor.participantID, {
      ...member,
      isCreator: member.handle === creatorHandle,
      isLocal: member.handle === localHandle,
    }]));
    this.participantOrder = members.map((member) => member.descriptor.participantID);
    for (const participantID of prior.keys()) {
      if (!this.participants.has(participantID)) this.removeParticipant(participantID, false);
    }
    this.reconcileFollow();
    this.changed("participants");
  }

  removeParticipant(participantID, notify = true) {
    this.participants.delete(participantID);
    this.sourcesByParticipant.delete(participantID);
    this.audioTracks.delete(participantID);
    this.peerStates.delete(participantID);
    for (const [key, cursor] of this.sourceCursors) if (cursor.ownerParticipantID === participantID) this.sourceCursors.delete(key);
    for (const key of this.nativePanBySource.keys()) if (key.startsWith(`${participantID}:`)) this.nativePanBySource.delete(key);
    for (const [trackID, track] of this.videoTracks) {
      if (track.participantID === participantID) this.videoTracks.delete(trackID);
    }
    this.reconcileFollow();
    if (notify) this.changed("participants");
  }

  clearRemoteMedia(participantID, notify = true) {
    this.sourcesByParticipant.delete(participantID);
    this.audioTracks.delete(participantID);
    for (const [trackID, track] of this.videoTracks) {
      if (track.participantID === participantID) this.videoTracks.delete(trackID);
    }
    for (const [key, cursor] of this.sourceCursors) if (cursor.ownerParticipantID === participantID) this.sourceCursors.delete(key);
    for (const key of this.nativePanBySource.keys()) if (key.startsWith(`${participantID}:`)) this.nativePanBySource.delete(key);
    this.reconcileFollow();
    if (notify) this.changed("tracks");
  }

  setPeerState(participantID, state, details = null) {
    const previous = this.peerStates.get(participantID);
    // Exact-codec incompatibility is a media fact, not an ICE state. Keep it
    // visible when a later connectionstatechange reports connecting/P2P.
    const stickyUnsupported = previous?.details?.unsupportedEncoding && details?.unsupportedEncoding !== false
      ? previous.details
      : null;
    const nextDetails = stickyUnsupported
      ? { ...(details ?? {}), ...stickyUnsupported, unsupportedEncoding: true }
      : details?.unsupportedEncoding === false
        ? Object.fromEntries(Object.entries(details).filter(([key]) => key !== "unsupportedEncoding"))
        : details;
    this.peerStates.set(participantID, { state, details: Object.keys(nextDetails ?? {}).length > 0 ? nextDetails : null });
    this.changed("peer-state");
  }

  clearUnsupportedEncoding(participantID) {
    const previous = this.peerStates.get(participantID);
    if (!previous?.details?.unsupportedEncoding) return;
    const details = Object.fromEntries(Object.entries(previous.details).filter(([key]) => !["unsupportedEncoding", "codec", "message"].includes(key)));
    this.peerStates.set(participantID, { ...previous, details: Object.keys(details).length > 0 ? details : null });
    this.changed("peer-state");
  }

  applySourceSnapshot(participantID, message) {
    const current = this.sourcesByParticipant.get(participantID);
    const snapshot = validateSourceSnapshot(message, { sessionId: this.sessionId, ownerParticipantID: participantID });
    if (current && snapshot.revision <= current.revision) return false;
    this.sourcesByParticipant.set(participantID, snapshot);
    const publishedKeys = new Set(snapshot.sources.map((source) => source.key));
    for (const [key, cursor] of this.sourceCursors) {
      if (cursor.ownerParticipantID === participantID && !publishedKeys.has(key)) this.sourceCursors.delete(key);
    }
    for (const key of this.nativePanBySource.keys()) {
      if (key.startsWith(`${participantID}:`) && !publishedKeys.has(key)) this.nativePanBySource.delete(key);
    }
    this.reconcileFollow();
    this.changed("sources");
    return true;
  }

  applySourceCursor(participantID, message) {
    const cursor = validateSourceCursor(message, { sessionId: this.sessionId, ownerParticipantID: participantID });
    const source = this.sourcesByParticipant.get(participantID)?.sources.find((entry) => entry.key === cursor.key);
    if (!source || source.streamID !== cursor.streamID) throw new Error("Source cursor does not match a published stream");
    const previous = this.sourceCursors.get(cursor.key);
    if (previous && cursor.sequence <= previous.sequence) return false;
    this.sourceCursors.set(cursor.key, Object.freeze({ ...cursor, ownerParticipantID: participantID }));
    this.changed("cursor");
    return true;
  }

  setVideoTrack(participantID, track, advertisedTrackID = track.id) {
    const existing = this.videoTracks.get(advertisedTrackID);
    if (existing?.track === track && existing.participantID === participantID) return;
    for (const [trackID, entry] of this.videoTracks) {
      if (entry.track === track && trackID !== advertisedTrackID) this.videoTracks.delete(trackID);
    }
    this.videoTracks.set(advertisedTrackID, { participantID, track, browserTrackID: track.id });
    track.addEventListener("ended", () => {
      if (this.videoTracks.get(advertisedTrackID)?.track === track) {
        this.videoTracks.delete(advertisedTrackID);
        this.changed("tracks");
      }
    }, { once: true });
    this.changed("tracks");
  }

  setAudioTrack(participantID, track) {
    if (this.audioTracks.get(participantID) === track) return;
    this.audioTracks.set(participantID, track);
    track.addEventListener("ended", () => {
      if (this.audioTracks.get(participantID) === track) {
        this.audioTracks.delete(participantID);
        this.changed("audio");
      }
    }, { once: true });
    this.changed("audio");
  }

  setLayout(layout) {
    if (!["focus", "row"].includes(layout) || layout === this.layout) return;
    this.layout = layout;
    this.changed("layout");
  }

  setScaleMode(mode) {
    if (!["fit", "fill", "native"].includes(mode) || mode === this.scaleMode) return;
    this.scaleMode = mode;
    this.changed("scale");
  }

  cursorForSource(source) {
    return source ? this.sourceCursors.get(source.key)?.position ?? null : null;
  }

  nativePanForSource(source) {
    return source ? this.nativePanBySource.get(source.key) ?? Object.freeze({ left: 0, top: 0 }) : null;
  }

  setNativePanForSource(sourceKey, { left, top }) {
    if (![left, top].every(Number.isFinite) || !this.allSources().some((source) => source.active && source.key === sourceKey)) return false;
    this.nativePanBySource.set(sourceKey, Object.freeze({ left, top }));
    return true;
  }

  clearNativePanForSource(sourceKey) {
    this.nativePanBySource.delete(sourceKey);
  }

  followParticipant(participantID) {
    if (participantID === null) {
      const currentSourceKey = this.selectedSource()?.key ?? this.selectedSourceKey;
      this.followEnabled = false;
      this.selectedSourceKey = currentSourceKey;
      this.reconcileFollow();
      this.changed("follow");
      return;
    }
    if (!this.participants.has(participantID)) return;
    this.followEnabled = true;
    this.followParticipantID = participantID;
    this.selectedSourceKey = null;
    this.reconcileFollow();
    this.changed("follow");
  }

  selectSource(sourceKey) {
    const source = this.allSources().find((entry) => entry.key === sourceKey);
    if (!source?.active) return;
    this.followEnabled = false;
    this.selectedSourceKey = source.key;
    this.changed("follow");
  }

  reconcileFollow() {
    const sourceMap = new Map([...this.sourcesByParticipant].map(([participantID, snapshot]) => [participantID, snapshot.sources]));
    if (!this.followEnabled) {
      const next = reconcileManualSelection({
        participantOrder: this.participantOrder,
        sourcesByParticipant: sourceMap,
        selectedSourceKey: this.selectedSourceKey,
      });
      this.selectedSourceKey = next.selectedSourceKey;
      if (this.followParticipantID && !this.participants.has(this.followParticipantID)) this.followParticipantID = null;
      return;
    }
    const next = reconcileFollowState({
      participantOrder: this.participantOrder,
      sourcesByParticipant: sourceMap,
      followParticipantID: this.followParticipantID,
      selectedSourceKey: this.selectedSourceKey,
    });
    this.followParticipantID = next.followParticipantID;
    // Following a participant always follows that participant's native focus.
    // A viewer-selected source is meaningful only in explicit manual mode.
    this.selectedSourceKey = null;
  }

  allSources() {
    return this.participantOrder.flatMap((participantID) => this.sourcesByParticipant.get(participantID)?.sources ?? []);
  }

  renderableSources() {
    return this.allSources().filter((source) => source.active && this.trackForSource(source));
  }

  /// Resolves the requested Follow/manual source against tracks that actually
  /// exist in the browser. A MediaStreamTrack can end before the publisher's
  /// next source snapshot arrives; during that gap, keep showing another live
  /// source instead of leaving Focus on a black surface.
  renderableSelectedSource() {
    const sources = this.renderableSources();
    const selectedKey = this.selectedSource()?.key;
    return sources.find((source) => source.key === selectedKey) ?? sources[0] ?? null;
  }

  selectedSource() {
    if (!this.followEnabled) {
      return this.allSources().find((source) => source.active && source.key === this.selectedSourceKey) ?? null;
    }
    const sources = this.followParticipantID ? this.sourcesByParticipant.get(this.followParticipantID)?.sources ?? [] : [];
    return chooseFollowSource(sources);
  }

  get followMode() { return this.followEnabled ? "participant" : "manual"; }

  trackForSource(source) {
    return source ? this.videoTracks.get(source.mediaTrackID)?.track ?? null : null;
  }

  changed(reason) {
    this.dispatchEvent(new CustomEvent("change", { detail: { reason } }));
  }
}
