const UNAVAILABLE = "Unavailable";

export class ClipWebDiagnosticsSampler {
  constructor() {
    this.previousInbound = new Map();
  }

  async sample(session) {
    const members = [...session.media.participants.values()];
    const remoteMembers = members.filter((member) => !member.isLocal);
    const peers = await Promise.all(remoteMembers.map(async (member) => {
      const peer = session.peers.get(member.handle) ?? null;
      return this.samplePeer(session, member, peer);
    }));
    const activeSources = session.media.renderableSources().length;
    return Object.freeze({
      generatedAt: new Date().toISOString(),
      roomCode: session.invite.roomCode,
      sessionState: session.state,
      participantCount: members.length,
      directLinkCount: peers.filter((peer) => peer.connectionState === "connected").length,
      activeSources,
      peers: Object.freeze(peers),
    });
  }

  async samplePeer(session, member, peer) {
    const participantID = member.descriptor.participantID;
    const storedState = session.media.peerStates.get(participantID) ?? null;
    const base = {
      participantID,
      displayName: member.descriptor.displayName,
      clientKind: member.descriptor.clientKind === "webViewer" ? "WEB" : "NATIVE",
      membershipState: member.connected ? "Connected" : "Disconnected",
      connectionState: peer?.connection?.connectionState ?? storedState?.state ?? UNAVAILABLE,
      signalingState: peer?.connection?.signalingState ?? UNAVAILABLE,
      iceState: peer?.connection?.iceConnectionState ?? UNAVAILABLE,
      controlState: peer?.controlChannel?.readyState ?? UNAVAILABLE,
      route: Object.freeze({ label: UNAVAILABLE, detail: null }),
      roundTripTimeMs: null,
      tracks: Object.freeze([]),
      error: storedState?.details?.message ?? null,
    };
    if (!peer?.connection?.getStats) return Object.freeze(base);

    let report;
    try {
      report = await peer.connection.getStats();
    } catch (error) {
      return Object.freeze({ ...base, error: String(error?.message ?? error) });
    }
    const stats = statsMap(report);
    const pair = selectedCandidatePair(stats);
    const localCandidate = pair ? stats.get(pair.localCandidateId) : null;
    const remoteCandidate = pair ? stats.get(pair.remoteCandidateId) : null;
    const tracks = [...stats.values()]
      .filter((entry) => entry.type === "inbound-rtp" && entry.isRemote !== true && mediaKind(entry))
      .filter((entry) => hasReceivedMedia(entry))
      .map((entry) => this.inboundTrack(session, member, peer, entry, stats));
    addObservableTrackFallbacks(session, member, tracks);

    return Object.freeze({
      ...base,
      connectionState: peer.connection.connectionState ?? base.connectionState,
      signalingState: peer.connection.signalingState ?? base.signalingState,
      iceState: peer.connection.iceConnectionState ?? base.iceState,
      route: Object.freeze(routePresentation(pair, localCandidate, remoteCandidate)),
      roundTripTimeMs: finiteNumber(pair?.currentRoundTripTime) ? Math.round(pair.currentRoundTripTime * 1000) : null,
      tracks: Object.freeze(tracks.map(Object.freeze)),
    });
  }

  inboundTrack(session, member, peer, entry, stats) {
    const kind = mediaKind(entry);
    const codec = stats.get(entry.codecId);
    const counterKey = `${member.descriptor.participantID}:${entry.id}`;
    const prior = this.previousInbound.get(counterKey) ?? null;
    const elapsedSeconds = prior && finiteNumber(entry.timestamp) && entry.timestamp > prior.timestamp
      ? (entry.timestamp - prior.timestamp) / 1000
      : null;
    const bitrateKbps = elapsedSeconds && finiteNumber(entry.bytesReceived) && entry.bytesReceived >= prior.bytesReceived
      ? Math.round(((entry.bytesReceived - prior.bytesReceived) * 8) / elapsedSeconds / 1000)
      : null;
    const decodedFPS = elapsedSeconds && finiteNumber(entry.framesDecoded) && entry.framesDecoded >= prior.framesDecoded
      ? (entry.framesDecoded - prior.framesDecoded) / elapsedSeconds
      : null;
    this.previousInbound.set(counterKey, {
      timestamp: entry.timestamp,
      bytesReceived: finiteNumber(entry.bytesReceived) ? entry.bytesReceived : 0,
      framesDecoded: finiteNumber(entry.framesDecoded) ? entry.framesDecoded : 0,
    });
    const advertisedTrackID = peer.remoteTrackIDsByMID?.get(entry.mid) ?? entry.trackIdentifier ?? null;
    const source = session.media.allSources().find((candidate) =>
      candidate.ownerParticipantID === member.descriptor.participantID &&
      advertisedTrackID && candidate.mediaTrackID === advertisedTrackID,
    );
    return {
      id: entry.id,
      mediaTrackID: advertisedTrackID,
      kind,
      label: kind === "video" ? sourceTitle(source) : "System Audio",
      codec: codecName(codec),
      width: finiteNumber(entry.frameWidth) ? entry.frameWidth : null,
      height: finiteNumber(entry.frameHeight) ? entry.frameHeight : null,
      fps: finiteNumber(entry.framesPerSecond) ? rounded(entry.framesPerSecond) : finiteNumber(decodedFPS) ? rounded(decodedFPS) : null,
      bitrateKbps,
      packetsLost: finiteNumber(entry.packetsLost) ? entry.packetsLost : null,
      bytesReceived: finiteNumber(entry.bytesReceived) ? entry.bytesReceived : null,
    };
  }
}

export function formatWebDiagnostics(snapshot) {
  const lines = [
    `Clip Web Viewer Diagnostics · ${snapshot.generatedAt}`,
    `Room ${snapshot.roomCode} · ${snapshot.sessionState}`,
    `${snapshot.participantCount} participants · ${snapshot.directLinkCount} direct links · ${snapshot.activeSources} visible sources`,
  ];
  for (const peer of snapshot.peers) {
    lines.push("", `${peer.displayName} · ${peer.clientKind}`);
    lines.push(`Connection: ${peer.connectionState} · ICE ${peer.iceState} · signaling ${peer.signalingState}`);
    lines.push(`Route: ${peer.route.label}${peer.route.detail ? ` (${peer.route.detail})` : ""} · RTT ${formatMetric(peer.roundTripTimeMs, "ms")}`);
    lines.push(`Control: ${peer.controlState}`);
    if (peer.error) lines.push(`Last issue: ${peer.error}`);
    if (peer.tracks.length === 0) lines.push("Incoming media: None reported");
    for (const track of peer.tracks) {
      const dimensions = track.width && track.height ? `${track.width}×${track.height}` : UNAVAILABLE;
      lines.push(`${track.kind === "video" ? "Video" : "Audio"}: ${track.label} · ${track.codec ?? UNAVAILABLE} · ${dimensions} · ${formatMetric(track.fps, "FPS")} · ${formatMetric(track.bitrateKbps, "kbps")} · ${formatMetric(track.packetsLost, "lost")}`);
    }
  }
  return lines.join("\n");
}

function statsMap(report) {
  if (report instanceof Map) return report;
  const values = new Map();
  report?.forEach?.((entry) => values.set(entry.id, entry));
  return values;
}

function selectedCandidatePair(stats) {
  const transport = [...stats.values()].find((entry) => entry.type === "transport" && entry.selectedCandidatePairId);
  if (transport) return stats.get(transport.selectedCandidatePairId) ?? null;
  return [...stats.values()].find((entry) =>
    entry.type === "candidate-pair" &&
    entry.state === "succeeded" &&
    (entry.selected === true || entry.nominated === true),
  ) ?? null;
}

function routePresentation(pair, localCandidate, remoteCandidate) {
  if (!pair) return { label: UNAVAILABLE, detail: null };
  const candidates = [localCandidate, remoteCandidate].filter(Boolean);
  const usesRelay = candidates.some((candidate) => candidate.candidateType === "relay");
  const protocol = localCandidate?.relayProtocol || localCandidate?.protocol || remoteCandidate?.protocol || null;
  const family = candidates.some((candidate) => String(candidate.address ?? "").includes(":")) ? "IPv6" : candidates.some((candidate) => candidate.address) ? "IPv4" : null;
  return {
    label: usesRelay ? "TURN" : "P2P",
    detail: [protocol?.toUpperCase(), family].filter(Boolean).join(" · ") || null,
  };
}

function addObservableTrackFallbacks(session, member, tracks) {
  const participantID = member.descriptor.participantID;
  const observedVideoIDs = new Set(tracks.filter((track) => track.kind === "video").map((track) => track.mediaTrackID).filter(Boolean));
  for (const [trackID, entry] of session.media.videoTracks) {
    if (entry.participantID !== participantID || observedVideoIDs.has(trackID)) continue;
    const settings = entry.track.getSettings?.() ?? {};
    const source = session.media.allSources().find((candidate) => candidate.ownerParticipantID === participantID && candidate.mediaTrackID === trackID);
    tracks.push({
      id: trackID,
      mediaTrackID: trackID,
      kind: "video",
      label: sourceTitle(source),
      codec: null,
      width: finiteNumber(settings.width) ? settings.width : null,
      height: finiteNumber(settings.height) ? settings.height : null,
      fps: finiteNumber(settings.frameRate) ? rounded(settings.frameRate) : null,
      bitrateKbps: null,
      packetsLost: null,
      bytesReceived: null,
    });
  }
  const audio = session.media.audioTracks.get(participantID);
  if (audio && !tracks.some((track) => track.kind === "audio")) {
    tracks.push({
      id: audio.id,
      mediaTrackID: audio.id,
      kind: "audio",
      label: "System Audio",
      codec: null,
      width: null,
      height: null,
      fps: null,
      bitrateKbps: null,
      packetsLost: null,
      bytesReceived: null,
    });
  }
}

function sourceTitle(source) {
  return source?.windowName || source?.appName || "Shared Video";
}

function mediaKind(entry) {
  const kind = entry.kind ?? entry.mediaType;
  return kind === "video" || kind === "audio" ? kind : null;
}

function hasReceivedMedia(entry) {
  return [entry.bytesReceived, entry.packetsReceived, entry.framesDecoded, entry.audioLevel].some((value) => finiteNumber(value) && value > 0);
}

function codecName(codec) {
  if (typeof codec?.mimeType !== "string") return null;
  return codec.mimeType.split("/").at(-1)?.toUpperCase().replace("H264", "H.264") ?? null;
}

function formatMetric(value, unit) {
  return finiteNumber(value) ? `${value} ${unit}` : UNAVAILABLE;
}

function rounded(value) {
  return Math.round(value * 10) / 10;
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}
