import {
  chooseFollowSource,
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
    this.followParticipantID = null;
    this.selectedSourceKey = null;
    this.layout = "focus";
    this.scaleMode = "fit";
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
    if (!["focus", "grid", "row"].includes(layout)) return;
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

  followParticipant(participantID) {
    if (participantID !== null && !this.participants.has(participantID)) return;
    this.followParticipantID = participantID;
    this.selectedSourceKey = null;
    this.reconcileFollow();
    this.changed("follow");
  }

  selectSource(sourceKey) {
    const source = this.allSources().find((entry) => entry.key === sourceKey);
    if (!source) return;
    this.followParticipantID = source.ownerParticipantID;
    this.selectedSourceKey = source.key;
    this.changed("follow");
  }

  reconcileFollow() {
    const sourceMap = new Map([...this.sourcesByParticipant].map(([participantID, snapshot]) => [participantID, snapshot.sources]));
    const next = reconcileFollowState({
      participantOrder: this.participantOrder,
      sourcesByParticipant: sourceMap,
      followParticipantID: this.followParticipantID,
      selectedSourceKey: this.selectedSourceKey,
    });
    this.followParticipantID = next.followParticipantID;
    this.selectedSourceKey = next.selectedSourceKey;
  }

  allSources() {
    return this.participantOrder.flatMap((participantID) => this.sourcesByParticipant.get(participantID)?.sources ?? []);
  }

  selectedSource() {
    const sources = this.followParticipantID ? this.sourcesByParticipant.get(this.followParticipantID)?.sources ?? [] : [];
    return chooseFollowSource(sources, this.selectedSourceKey);
  }

  trackForSource(source) {
    return source ? this.videoTracks.get(source.mediaTrackID)?.track ?? null : null;
  }

  changed(reason) {
    this.dispatchEvent(new CustomEvent("change", { detail: { reason } }));
  }
}
