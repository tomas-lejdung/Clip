import assert from "node:assert/strict";
import test from "node:test";

import { ClipWebDiagnosticsSampler, formatWebDiagnostics } from "../assets/clip-web-diagnostics.js";

function member(handle, participantID, { local = false, kind = "nativeApp" } = {}) {
  return {
    handle,
    connected: true,
    isLocal: local,
    descriptor: {
      participantID,
      displayName: local ? "Safari" : "Tomas’s MacBook Pro",
      clientKind: kind,
    },
  };
}

function statsReport({ timestamp, bytesReceived, framesDecoded, relay = false }) {
  return new Map([
    ["transport", { id: "transport", type: "transport", selectedCandidatePairId: "pair" }],
    ["pair", {
      id: "pair", type: "candidate-pair", state: "succeeded", nominated: true,
      localCandidateId: "local", remoteCandidateId: "remote", currentRoundTripTime: 0.023,
    }],
    ["local", { id: "local", type: "local-candidate", candidateType: relay ? "relay" : "host", protocol: "udp", address: "192.0.2.1" }],
    ["remote", { id: "remote", type: "remote-candidate", candidateType: "srflx", protocol: "udp", address: "198.51.100.2" }],
    ["codec", { id: "codec", type: "codec", mimeType: "video/VP8" }],
    ["video", {
      id: "video", type: "inbound-rtp", kind: "video", mid: "0", codecId: "codec",
      timestamp, bytesReceived, packetsReceived: 100, packetsLost: 2, framesDecoded,
      framesPerSecond: 29.8, frameWidth: 1360, frameHeight: 1006,
    }],
  ]);
}

function sessionWithReports(reports) {
  const local = member("local", "local-id", { local: true, kind: "webViewer" });
  const remote = member("remote", "remote-id");
  let index = 0;
  const track = { id: "browser-track", getSettings: () => ({ width: 1360, height: 1006, frameRate: 30 }) };
  return {
    state: "connected",
    invite: { roomCode: "CLEAN-JUNGLE-714", secret: "must-not-copy" },
    media: {
      participants: new Map([[local.descriptor.participantID, local], [remote.descriptor.participantID, remote]]),
      peerStates: new Map([[remote.descriptor.participantID, { state: "p2p", details: null }]]),
      videoTracks: new Map([["advertised-video", { participantID: remote.descriptor.participantID, track }]]),
      audioTracks: new Map(),
      renderableSources: () => [{ key: "remote:window" }],
      allSources: () => [{
        key: "remote:window", ownerParticipantID: remote.descriptor.participantID,
        mediaTrackID: "advertised-video", windowName: "Scratch", active: true,
      }],
    },
    peers: new Map([[remote.handle, {
      connection: {
        connectionState: "connected", signalingState: "stable", iceConnectionState: "connected",
        getStats: async () => reports[Math.min(index++, reports.length - 1)],
      },
      controlChannel: { readyState: "open" },
      remoteTrackIDsByMID: new Map([["0", "advertised-video"]]),
    }]]),
  };
}

test("diagnostics report a selected direct route and measured inbound media", async () => {
  const sampler = new ClipWebDiagnosticsSampler();
  const session = sessionWithReports([
    statsReport({ timestamp: 1_000, bytesReceived: 100_000, framesDecoded: 30 }),
    statsReport({ timestamp: 2_000, bytesReceived: 350_000, framesDecoded: 60 }),
  ]);
  await sampler.sample(session);
  const snapshot = await sampler.sample(session);
  assert.equal(snapshot.roomCode, "CLEAN-JUNGLE-714");
  assert.equal(snapshot.participantCount, 2);
  assert.equal(snapshot.directLinkCount, 1);
  assert.equal(snapshot.peers[0].route.label, "P2P");
  assert.equal(snapshot.peers[0].route.detail, "UDP · IPv4");
  assert.equal(snapshot.peers[0].roundTripTimeMs, 23);
  assert.deepEqual(snapshot.peers[0].tracks, [{
    id: "video", mediaTrackID: "advertised-video", kind: "video", label: "Scratch", codec: "VP8",
    width: 1360, height: 1006, fps: 29.8, bitrateKbps: 2000,
    packetsLost: 2, bytesReceived: 350_000,
  }]);
});

test("relay routes are labeled TURN and copied diagnostics omit invite secrets", async () => {
  const sampler = new ClipWebDiagnosticsSampler();
  const session = sessionWithReports([statsReport({ timestamp: 1_000, bytesReceived: 100_000, framesDecoded: 30, relay: true })]);
  const snapshot = await sampler.sample(session);
  assert.equal(snapshot.peers[0].route.label, "TURN");
  const text = formatWebDiagnostics(snapshot);
  assert.match(text, /Room CLEAN-JUNGLE-714 · connected/u);
  assert.match(text, /Route: TURN \(UDP · IPv4\)/u);
  assert.match(text, /Video: Scratch · VP8 · 1360×1006/u);
  assert.doesNotMatch(text, /must-not-copy/u);
});

test("diagnostics remain honest when browser peer stats are unavailable", async () => {
  const session = sessionWithReports([]);
  session.peers.get("remote").connection.getStats = async () => { throw new Error("stats disabled"); };
  const snapshot = await new ClipWebDiagnosticsSampler().sample(session);
  assert.equal(snapshot.peers[0].route.label, "Unavailable");
  assert.equal(snapshot.peers[0].tracks.length, 0);
  assert.equal(snapshot.peers[0].error, "stats disabled");
  assert.match(formatWebDiagnostics(snapshot), /Incoming media: None reported/u);
});

test("unused preallocated receiver slots are hidden while real audio and advertised video remain", async () => {
  const report = statsReport({ timestamp: 1_000, bytesReceived: 100_000, framesDecoded: 30 });
  report.set("placeholder-codec", { id: "placeholder-codec", type: "codec", mimeType: "video/VP8" });
  report.set("placeholder-video", {
    id: "placeholder-video", type: "inbound-rtp", kind: "video", mid: "1", codecId: "placeholder-codec",
    timestamp: 1_000, bytesReceived: 8_000, packetsReceived: 8, packetsLost: 0, framesDecoded: 1,
    framesPerSecond: 0, frameWidth: 16, frameHeight: 16,
  });
  report.set("audio-codec", { id: "audio-codec", type: "codec", mimeType: "audio/opus" });
  report.set("audio", {
    id: "audio", type: "inbound-rtp", kind: "audio", mid: "4", codecId: "audio-codec",
    timestamp: 1_000, bytesReceived: 12_000, packetsReceived: 20, packetsLost: 0,
  });
  const session = sessionWithReports([report]);
  const placeholder = { id: "placeholder-browser-track", getSettings: () => ({ width: 16, height: 16 }) };
  session.media.videoTracks.set("unused-native-slot", { participantID: "remote-id", track: placeholder });
  session.media.audioTracks.set("remote-id", { id: "audio-browser-track" });
  session.peers.get("remote").remoteTrackIDsByMID.set("1", "unused-native-slot");

  const snapshot = await new ClipWebDiagnosticsSampler().sample(session);
  assert.deepEqual(snapshot.peers[0].tracks.map((track) => [track.kind, track.label, track.codec]), [
    ["video", "Scratch", "VP8"],
    ["audio", "System Audio", "OPUS"],
  ]);
  assert.equal(snapshot.peers[0].tracks.some((track) => track.mediaTrackID === "unused-native-slot"), false);
});
