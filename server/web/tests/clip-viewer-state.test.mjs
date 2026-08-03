import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

globalThis.crypto ??= webcrypto;
const {
  chooseFollowParticipant,
  chooseFollowSource,
  createAnimationFrameCoalescer,
  emptyWebSourceSnapshot,
  nativePanGeometry,
  nativeManualPanGeometry,
  nativeMinimapGeometry,
  participantConnectionState,
  reconcileManualSelection,
  reconcileFollowState,
  snapToDevicePixel,
  unsupportedEncodingPresentation,
  validateSourceCursor,
  validateSourceSnapshot,
} = await import("../assets/clip-viewer-state.js");
const { ClipWebMeshPeer, firstOfferedVideoCodec, PAIR_EPOCH, parseRemoteTrackBindings, validatePairPayload } = await import("../assets/clip-mesh-peer.js");
const {
  ClipWebReconnectError,
  ClipWebRoomSession,
  isExpectedRoomSubprotocol,
  nextReconnectCapability,
  resolveBrowserTabIdentity,
  shouldReconnectRoomState,
} = await import("../assets/clip-room-session.js");
const { ClipWebMediaStore } = await import("../assets/clip-media-store.js");
const { ClipSerialQueue } = await import("../assets/clip-serial-queue.js");

const sources = (owner, entries) => entries.map((entry, index) => ({
  key: `${owner}:${entry.name}`,
  ownerParticipantID: owner,
  active: entry.active ?? true,
  focused: entry.focused ?? false,
  order: index,
}));

const fixtureID = (byte) => Buffer.alloc(16, byte).toString("base64url");

function nativeSnapshot({ owner, label, sourceByte, focusedOrder, revision = 1, empty = false }) {
  return {
    version: 4,
    type: "source-snapshot",
    payload: {
      version: 3,
      sessionId: "full-room",
      membershipRevision: 1,
      ownerParticipantId: owner,
      sourceRevision: revision,
      // Reverse the wire order so the store must preserve the canonical
      // per-publisher order supplied by the validated source descriptors.
      sources: empty ? [] : [3, 2, 1, 0].map((order) => {
        const sourceInstanceID = fixtureID(sourceByte + order);
        return {
          key: { ownerParticipantId: owner, sourceInstanceId: sourceInstanceID },
          descriptor: {
            sourceInstanceId: sourceInstanceID,
            stream: {
              id: `${label}-stream-${order}`,
              mediaTrackId: `${label}-track-${order}`,
              active: true,
              focused: order === focusedOrder,
              appName: `${label} App`,
              windowName: `${label} Window ${order}`,
              width: 1_920,
              height: 1_080,
              sourcePointWidth: 960,
              sourcePointHeight: 540,
              order,
            },
          },
        };
      }),
    },
  };
}

function roomMember(handle, participantID, clientKind = "nativeApp") {
  return {
    handle,
    connected: true,
    descriptor: {
      participantID,
      displayName: handle,
      deviceName: `${handle} Device`,
      clientKind,
      capabilityProfile: clientKind === "webViewer" ? "webViewerV1" : "nativeV1",
    },
  };
}

test("follow keeps a selected sharer, then advances in stable roster order", () => {
  const map = new Map([
    ["A", sources("A", [{ name: "a" }])],
    ["B", sources("B", [{ name: "b", focused: true }])],
    ["C", sources("C", [{ name: "c" }])],
  ]);
  assert.equal(chooseFollowParticipant({ participantOrder: ["A", "B", "C"], sourcesByParticipant: map, currentParticipantID: "B" }), "B");
  map.set("B", []);
  assert.deepEqual(reconcileFollowState({ participantOrder: ["A", "B", "C"], sourcesByParticipant: map, followParticipantID: "B", selectedSourceKey: "B:b" }), {
    followParticipantID: "A", selectedSourceKey: null,
  });
});

test("follow uses focused source without letting a new source steal an explicit selection", () => {
  const entries = sources("A", [{ name: "first" }, { name: "second", focused: true }]);
  assert.equal(chooseFollowSource(entries).key, "A:second");
  assert.equal(chooseFollowSource(entries, "A:first").key, "A:first");
});

test("participant Follow tracks native focus while an explicit source click enters pinned manual mode", () => {
  const media = new ClipWebMediaStore("room");
  media.participantOrder = ["A"];
  const first = sources("A", [{ name: "first", focused: true }, { name: "second" }]);
  media.sourcesByParticipant.set("A", { revision: 1, sources: first });
  media.reconcileFollow();
  assert.equal(media.selectedSourceKey, null);
  assert.equal(media.selectedSource().key, "A:first");

  const second = sources("A", [{ name: "first" }, { name: "second", focused: true }]);
  media.sourcesByParticipant.set("A", { revision: 2, sources: second });
  media.reconcileFollow();
  assert.equal(media.selectedSourceKey, null);
  assert.equal(media.selectedSource().key, "A:second");

  media.selectSource("A:first");
  media.reconcileFollow();
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSourceKey, "A:first");
  assert.equal(media.selectedSource().key, "A:first");
});

test("viewer defaults to Native Focus and accepts only Focus or Row layouts", () => {
  const media = new ClipWebMediaStore("room");
  assert.equal(media.scaleMode, "native");
  assert.equal(media.layout, "focus");
  media.setLayout("grid");
  assert.equal(media.layout, "focus");
  media.setLayout("row");
  assert.equal(media.layout, "row");
  media.setLayout("focus");
  assert.equal(media.layout, "focus");
});

test("Focus falls back when its selected track ends before the source snapshot changes", () => {
  const media = new ClipWebMediaStore("room");
  media.participants = new Map([["A", {}], ["B", {}]]);
  media.participantOrder = ["A", "B"];
  const first = {
    ...sources("A", [{ name: "first", focused: true }])[0],
    mediaTrackID: "track-first",
  };
  const second = {
    ...sources("B", [{ name: "second", focused: true }])[0],
    mediaTrackID: "track-second",
  };
  media.sourcesByParticipant.set("A", { revision: 1, sources: [first] });
  media.sourcesByParticipant.set("B", { revision: 1, sources: [second] });
  media.followParticipant("A");

  const firstTrack = Object.assign(new EventTarget(), { id: "browser-first" });
  const secondTrack = Object.assign(new EventTarget(), { id: "browser-second" });
  media.setVideoTrack("A", firstTrack, first.mediaTrackID);
  media.setVideoTrack("B", secondTrack, second.mediaTrackID);
  assert.equal(media.renderableSelectedSource()?.key, first.key);

  firstTrack.dispatchEvent(new Event("ended"));
  assert.equal(media.selectedSource()?.key, first.key);
  assert.equal(media.renderableSelectedSource()?.key, second.key);
  assert.deepEqual(media.renderableSources().map((source) => source.key), [second.key]);
});

test("Follow Off pins manual selection and replaces only a disappeared source", () => {
  const media = new ClipWebMediaStore("room");
  media.participants = new Map([["A", {}], ["B", {}]]);
  media.participantOrder = ["A", "B"];
  media.sourcesByParticipant.set("A", { revision: 1, sources: sources("A", [
    { name: "first", focused: true },
    { name: "second" },
  ]) });
  media.sourcesByParticipant.set("B", { revision: 1, sources: sources("B", [
    { name: "third", focused: true },
  ]) });
  media.reconcileFollow();
  assert.equal(media.followMode, "participant");
  assert.equal(media.followParticipantID, "A");
  assert.equal(media.selectedSource().key, "A:first");

  media.followParticipant(null);
  assert.equal(media.selectedSource().key, "A:first");
  media.selectSource("A:second");
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSource().key, "A:second");

  media.sourcesByParticipant.set("A", { revision: 2, sources: sources("A", [
    { name: "first" },
    { name: "second" },
  ]) });
  media.reconcileFollow();
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSource().key, "A:second");

  media.sourcesByParticipant.set("A", { revision: 3, sources: [] });
  media.reconcileFollow();
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSource().key, "B:third");

  media.sourcesByParticipant.set("A", { revision: 4, sources: sources("A", [{ name: "returned" }]) });
  media.selectSource("A:returned");
  media.removeParticipant("A", false);
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSource().key, "B:third");
});

test("following a participant tracks native focus and fails over in roster order", () => {
  const media = new ClipWebMediaStore("room");
  media.participants = new Map([["A", {}], ["B", {}]]);
  media.participantOrder = ["A", "B"];
  media.sourcesByParticipant.set("A", { revision: 1, sources: sources("A", [
    { name: "first", focused: true }, { name: "second" },
  ]) });
  media.sourcesByParticipant.set("B", { revision: 1, sources: sources("B", [{ name: "third", focused: true }]) });
  media.followParticipant("B");
  assert.equal(media.selectedSource().key, "B:third");
  media.followParticipant(null);
  assert.equal(media.followMode, "manual");
  assert.equal(media.selectedSource().key, "B:third");

  media.followParticipant("A");
  assert.equal(media.selectedSource().key, "A:first");

  media.sourcesByParticipant.set("A", { revision: 2, sources: sources("A", [
    { name: "first" }, { name: "second", focused: true },
  ]) });
  media.reconcileFollow();
  assert.equal(media.followMode, "participant");
  assert.equal(media.selectedSource().key, "A:second");

  media.sourcesByParticipant.set("A", { revision: 3, sources: [] });
  media.reconcileFollow();
  assert.equal(media.followParticipantID, "B");
  assert.equal(media.selectedSource().key, "B:third");
});

test("manual reconciliation is deterministic and independent from a Follow target", () => {
  const map = new Map([
    ["B", sources("B", [{ name: "later" }])],
    ["A", sources("A", [{ name: "second" }, { name: "first" }])],
  ]);
  assert.deepEqual(reconcileManualSelection({
    participantOrder: ["A", "B"], sourcesByParticipant: map, selectedSourceKey: "missing",
  }), { selectedSourceKey: "A:second" });
  assert.deepEqual(reconcileManualSelection({
    participantOrder: ["A", "B"], sourcesByParticipant: map, selectedSourceKey: "B:later",
  }), { selectedSourceKey: "B:later" });
});

test("full room retains twelve native source slots in roster order and fails Follow over deterministically", () => {
  const media = new ClipWebMediaStore("full-room");
  const nativeB = { id: fixtureID(0x12), label: "B", sourceByte: 0x50, focusedOrder: 1, handle: "B" };
  const nativeA = { id: fixtureID(0x11), label: "A", sourceByte: 0x40, focusedOrder: 3, handle: "A" };
  const nativeC = { id: fixtureID(0x13), label: "C", sourceByte: 0x60, focusedOrder: 2, handle: "C" };
  const localWeb = roomMember("Web", fixtureID(0x20), "webViewer");
  const participants = [
    roomMember(nativeB.handle, nativeB.id),
    roomMember(nativeA.handle, nativeA.id),
    localWeb,
    roomMember(nativeC.handle, nativeC.id),
  ];
  media.setParticipants(participants, nativeB.handle, localWeb.handle);

  // Arrival order deliberately differs from authoritative roster order. The
  // first publisher remains the Follow target until it stops, while the
  // aggregate source presentation remains roster-stable.
  for (const publisher of [nativeC, nativeA, nativeB]) {
    assert.equal(media.applySourceSnapshot(
      publisher.id,
      nativeSnapshot({ owner: publisher.id, ...publisher }),
    ), true);
    for (const source of media.sourcesByParticipant.get(publisher.id).sources) {
      media.setVideoTrack(publisher.id, {
        id: `browser-${source.mediaTrackID}`,
        kind: "video",
        addEventListener() {},
      }, source.mediaTrackID);
    }
  }

  const expectedTrackOrder = [nativeB, nativeA, nativeC]
    .flatMap((publisher) => [0, 1, 2, 3].map((order) => `${publisher.label}-track-${order}`));
  assert.deepEqual(media.allSources().map((source) => source.mediaTrackID), expectedTrackOrder);
  assert.equal(media.allSources().length, 12);
  assert.equal(media.videoTracks.size, 12);
  for (const source of media.allSources()) {
    assert.equal(media.trackForSource(source), media.videoTracks.get(source.mediaTrackID).track);
  }

  assert.equal(media.followParticipantID, nativeC.id);
  assert.equal(media.selectedSource().mediaTrackID, "C-track-2");

  assert.equal(media.applySourceSnapshot(nativeC.id, nativeSnapshot({
    owner: nativeC.id, ...nativeC, revision: 2, empty: true,
  })), true);
  assert.equal(media.followParticipantID, nativeB.id);
  assert.equal(media.selectedSource().mediaTrackID, "B-track-1");

  assert.equal(media.applySourceSnapshot(nativeB.id, nativeSnapshot({
    owner: nativeB.id, ...nativeB, revision: 2, empty: true,
  })), true);
  assert.equal(media.followParticipantID, nativeA.id);
  assert.equal(media.selectedSource().mediaTrackID, "A-track-3");
});

test("one system-audio track per native publisher remains participant-scoped through cleanup and removal", () => {
  const media = new ClipWebMediaStore("full-room");
  const nativeIDs = [fixtureID(0x11), fixtureID(0x12), fixtureID(0x13)];
  const localWeb = roomMember("Web", fixtureID(0x20), "webViewer");
  media.setParticipants([
    ...nativeIDs.map((participantID, index) => roomMember(`Native ${index + 1}`, participantID)),
    localWeb,
  ], "Native 1", localWeb.handle);

  const tracks = nativeIDs.map((participantID, index) => ({
    id: `native-audio-${index + 1}`,
    kind: "audio",
    participantID,
    addEventListener() {},
  }));
  nativeIDs.forEach((participantID, index) => media.setAudioTrack(participantID, tracks[index]));
  assert.equal(media.audioTracks.size, 3);
  nativeIDs.forEach((participantID, index) => assert.equal(media.audioTracks.get(participantID), tracks[index]));

  media.clearRemoteMedia(nativeIDs[1]);
  assert.equal(media.participants.has(nativeIDs[1]), true);
  assert.equal(media.audioTracks.has(nativeIDs[1]), false);
  assert.equal(media.audioTracks.get(nativeIDs[0]), tracks[0]);
  assert.equal(media.audioTracks.get(nativeIDs[2]), tracks[2]);

  media.setAudioTrack(nativeIDs[1], tracks[1]);
  media.removeParticipant(nativeIDs[1]);
  assert.equal(media.participants.has(nativeIDs[1]), false);
  assert.deepEqual([...media.audioTracks.keys()], [nativeIDs[0], nativeIDs[2]]);
  assert.equal(media.audioTracks.get(nativeIDs[0]), tracks[0]);
  assert.equal(media.audioTracks.get(nativeIDs[2]), tracks[2]);
});

test("cursor render scheduling coalesces a burst into one animation frame", () => {
  const callbacks = [];
  const cancelled = [];
  let nextFrameID = 0;
  let renders = 0;
  const schedule = createAnimationFrameCoalescer(
    () => { renders += 1; },
    (callback) => { callbacks.push(callback); nextFrameID += 1; return nextFrameID; },
    (identifier) => cancelled.push(identifier),
  );
  schedule(); schedule(); schedule();
  assert.equal(callbacks.length, 1);
  callbacks.shift()();
  assert.equal(renders, 1);
  schedule();
  schedule.cancel();
  assert.deepEqual(cancelled, [2]);
});

test("source snapshot validates ownership and media fields", () => {
  const owner = "AgICAgICAgICAgICAgICAg";
  const sourceID = "AQEBAQEBAQEBAQEBAQEBAQ";
  const message = {
    version: 4, type: "source-snapshot", payload: {
      version: 3, sessionId: "room", membershipRevision: 1, ownerParticipantId: owner, sourceRevision: 2,
      sources: [{
        key: { ownerParticipantId: owner, sourceInstanceId: sourceID },
        descriptor: { sourceInstanceId: sourceID, stream: {
          id: "stream", mediaTrackId: "native-track", active: true, focused: true,
          appName: "App", windowName: "Window", width: 1920, height: 1080,
          sourcePointWidth: 960, sourcePointHeight: 540, order: 0,
        } },
      }],
    },
  };
  const expected = { sessionId: "room", ownerParticipantID: owner };
  const snapshot = validateSourceSnapshot(message, expected);
  assert.equal(snapshot.sources[0].mediaTrackID, "native-track");
  assert.throws(() => validateSourceSnapshot({ ...message, payload: { ...message.payload, ownerParticipantId: "attacker" } }, expected), /context/u);
  const invalidID = structuredClone(message);
  invalidID.payload.sources[0].descriptor.stream.mediaTrackId = "track id with spaces";
  assert.throws(() => validateSourceSnapshot(invalidID, expected), /descriptor/u);

  const invalidSourceID = structuredClone(message);
  invalidSourceID.payload.sources[0].key.sourceInstanceId = "too-short";
  invalidSourceID.payload.sources[0].descriptor.sourceInstanceId = "too-short";
  assert.throws(() => validateSourceSnapshot(invalidSourceID, expected), /descriptor/u);

  const invalidText = structuredClone(message);
  invalidText.payload.sources[0].descriptor.stream.windowName = "Window\u0000Name";
  assert.throws(() => validateSourceSnapshot(invalidText, expected), /descriptor/u);

  for (const membershipRevision of [0, 2]) {
    const invalidMembership = structuredClone(message);
    invalidMembership.payload.membershipRevision = membershipRevision;
    assert.throws(() => validateSourceSnapshot(invalidMembership, expected), /revision/u);
  }

  const oversizedText = structuredClone(message);
  oversizedText.payload.sources[0].descriptor.stream.appName = "x".repeat(513);
  assert.throws(() => validateSourceSnapshot(oversizedText, expected), /descriptor/u);

  for (const mutate of [
    (value) => { value.extra = true; },
    (value) => { value.payload.extra = true; },
    (value) => { value.payload.sources[0].extra = true; },
    (value) => { value.payload.sources[0].key.extra = true; },
    (value) => { value.payload.sources[0].descriptor.extra = true; },
    (value) => { value.payload.sources[0].descriptor.stream.extra = true; },
  ]) {
    const malformed = structuredClone(message);
    mutate(malformed);
    assert.throws(() => validateSourceSnapshot(malformed, expected), /shape/u);
  }
});

test("web empty snapshot stays at native media membership 1 after later roster revisions", () => {
  const value = emptyWebSourceSnapshot({ sessionId: "room", membershipRevision: 9, participantID: "web", sourceRevision: 4 });
  assert.equal(value.payload.membershipRevision, 1);
  assert.deepEqual(value.payload.sources, []);
});

test("source cursor is closed, source-bound, monotonic, and drives native pan", () => {
  const owner = "AgICAgICAgICAgICAgICAg";
  const sourceID = "AQEBAQEBAQEBAQEBAQEBAQ";
  const message = { version: 4, type: "source-cursor", payload: {
    sessionId: "room", participantId: owner,
    sourceKey: { ownerParticipantId: owner, sourceInstanceId: sourceID },
    streamId: "stream", sequence: 7, position: { x: 0.9, y: 0.1 },
  } };
  const cursor = validateSourceCursor(message, { sessionId: "room", ownerParticipantID: owner });
  assert.deepEqual(cursor.position, { x: 0.9, y: 0.1 });
  assert.throws(() => validateSourceCursor({ ...message, payload: { ...message.payload, extra: true } }, { sessionId: "room", ownerParticipantID: owner }), /shape/u);
  assert.throws(() => validateSourceCursor({ ...message, payload: { ...message.payload, position: { x: 2, y: 0 } } }, { sessionId: "room", ownerParticipantID: owner }), /position/u);

  assert.deepEqual(nativePanGeometry({ sourceWidth: 1000, sourceHeight: 800, viewportWidth: 400, viewportHeight: 300, cursor: cursor.position }), {
    width: 1000, height: 800, left: -600, top: 0,
  });
  assert.deepEqual(nativePanGeometry({ sourceWidth: 200, sourceHeight: 100, viewportWidth: 400, viewportHeight: 300, cursor: cursor.position }), {
    width: 200, height: 100, left: 100, top: 100,
  });

  const media = new ClipWebMediaStore("room");
  media.sourcesByParticipant.set(owner, { revision: 1, sources: [{ key: cursor.key, streamID: "stream", active: true }] });
  assert.equal(media.applySourceCursor(owner, message), true);
  assert.deepEqual(media.cursorForSource({ key: cursor.key }), { x: 0.9, y: 0.1 });
  assert.equal(media.applySourceCursor(owner, message), false);
  const wrongStream = structuredClone(message); wrongStream.payload.streamId = "replacement"; wrongStream.payload.sequence = 8;
  assert.throws(() => media.applySourceCursor(owner, wrongStream), /published stream/u);
  media.setScaleMode("native");
  assert.equal(media.scaleMode, "native");
});

test("manual Native pan clamps and aligns the fixed source surface to backing pixels", () => {
  assert.equal(snapToDevicePixel(-123.26, 2), -123.5);
  assert.deepEqual(nativeManualPanGeometry({
    sourceWidth: 1_000,
    sourceHeight: 800,
    viewportWidth: 400,
    viewportHeight: 300,
    left: -123.26,
    top: -900,
    devicePixelRatio: 2,
  }), {
    width: 1_000,
    height: 800,
    left: -123.5,
    top: -500,
  });
  assert.deepEqual(nativeManualPanGeometry({
    sourceWidth: 200,
    sourceHeight: 100,
    viewportWidth: 401,
    viewportHeight: 301,
    left: -80,
    top: -80,
    devicePixelRatio: 2,
  }), {
    width: 200,
    height: 100,
    left: 100.5,
    top: 100.5,
  });
});

test("manual Native pan state is source-specific and removed with its source", () => {
  const media = new ClipWebMediaStore("room");
  media.participantOrder = ["A"];
  media.sourcesByParticipant.set("A", { revision: 1, sources: sources("A", [
    { name: "first" }, { name: "second" },
  ]) });
  assert.deepEqual(media.nativePanForSource({ key: "A:first" }), { left: 0, top: 0 });
  assert.equal(media.setNativePanForSource("A:first", { left: -120.5, top: -40 }), true);
  assert.equal(media.setNativePanForSource("missing", { left: 1, top: 1 }), false);
  assert.deepEqual(media.nativePanForSource({ key: "A:first" }), { left: -120.5, top: -40 });
  assert.deepEqual(media.nativePanForSource({ key: "A:second" }), { left: 0, top: 0 });

  media.clearRemoteMedia("A", false);
  assert.deepEqual(media.nativePanForSource({ key: "A:first" }), { left: 0, top: 0 });
});

test("Native minimap describes the exact visible source viewport", () => {
  assert.deepEqual(nativeMinimapGeometry({
    sourceWidth: 1_000,
    sourceHeight: 800,
    viewportWidth: 400,
    viewportHeight: 300,
    left: -123.5,
    top: -500,
    maximumWidth: 120,
    maximumHeight: 90,
    devicePixelRatio: 2,
  }), {
    width: 112.5,
    height: 90,
    viewport: { left: 14, top: 56, width: 45, height: 34 },
  });
  assert.equal(nativeMinimapGeometry({
    sourceWidth: 200,
    sourceHeight: 100,
    viewportWidth: 400,
    viewportHeight: 300,
    left: 100,
    top: 100,
  }), null);
});

test("SDP MID maps native mediaTrackID when a browser rewrites MediaStreamTrack.id", () => {
  const sdp = [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=mid:0", "a=msid:native-stream native-track-id",
    "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:4", "a=msid:native-audio native-audio-id", "",
  ].join("\r\n");
  const bindings = parseRemoteTrackBindings(sdp);
  assert.equal(bindings.get("0"), "native-track-id");
  assert.equal(bindings.get("4"), "native-audio-id");
  assert.equal(firstOfferedVideoCodec(`${sdp}\r\na=rtpmap:96 VP8/90000\r\n`), null);
});

test("offered codec parser ignores RTX and reports selected video codec", () => {
  const sdp = [
    "v=0", "m=video 9 UDP/TLS/RTP/SAVPF 97 98", "a=mid:0",
    "a=rtpmap:97 rtx/90000", "a=rtpmap:98 AV1/90000", "",
  ].join("\r\n");
  assert.equal(firstOfferedVideoCodec(sdp), "AV1");
});

test("unsupported encoding presentation names a known exact codec without promising media", () => {
  const states = new Map([
    ["native", { state: "connected", details: { unsupportedEncoding: true, codec: "AV1" } }],
    ["other", { state: "p2p", details: null }],
  ]);
  const presentation = unsupportedEncodingPresentation(states);
  assert.equal(presentation.title, "Unsupported Encoding: AV1");
  assert.match(presentation.message, /will not fall back|second encoding/u);
  assert.match(presentation.message, /media on this peer edge may be unavailable/u);
  assert.equal(unsupportedEncodingPresentation(new Map()), null);
});

test("unsupported codec details remain sticky across ICE connection state updates", () => {
  const media = new ClipWebMediaStore("room");
  media.setPeerState("native", "connected", { unsupportedEncoding: true, codec: "AV1", message: "rejected" });
  media.setPeerState("native", "p2p");
  assert.deepEqual(media.peerStates.get("native"), {
    state: "p2p",
    details: { unsupportedEncoding: true, codec: "AV1", message: "rejected" },
  });
  assert.equal(unsupportedEncodingPresentation(media.peerStates).title, "Unsupported Encoding: AV1");
  media.clearUnsupportedEncoding("native");
  assert.equal(unsupportedEncodingPresentation(media.peerStates), null);
});

test("browser requires the exact native room WebSocket subprotocol", () => {
  assert.equal(isExpectedRoomSubprotocol("clip-native-room-v4"), true);
  assert.equal(isExpectedRoomSubprotocol(""), false);
  assert.equal(isExpectedRoomSubprotocol("reconnect.secret"), false);
  assert.equal(isExpectedRoomSubprotocol("clip-native-room-v3"), false);
});

test("denial states suppress reconnect and access-word retry opens a fresh candidate", async () => {
  assert.equal(shouldReconnectRoomState("access-word"), false);
  assert.equal(shouldReconnectRoomState("denied"), false);
  assert.equal(shouldReconnectRoomState("full"), false);
  assert.equal(shouldReconnectRoomState("reconnect-failed"), false);
  assert.equal(shouldReconnectRoomState("reconnecting"), true);

  const room = new ClipWebRoomSession({
    invite: { sessionId: "test" }, identity: {}, iceServers: [],
  });
  let closed = false;
  room.socket = { close() { closed = true; } };
  room.localHandle = "old";
  room.reconnectCapability = "secret";
  let connected = 0;
  room.connect = async () => { connected += 1; };
  await room.retryAdmission("WORD");
  assert.equal(closed, true);
  assert.equal(room.localHandle, null);
  assert.equal(room.reconnectCapability, null);
  assert.equal(room.accessWord, "WORD");
  assert.equal(connected, 1);
});

test("reconnect admission keeps an existing capability when the snapshot omits it", () => {
  assert.equal(nextReconnectCapability("persisted-secret", undefined), "persisted-secret");
  assert.equal(nextReconnectCapability("persisted-secret", "rotated-secret"), "rotated-secret");
  assert.equal(nextReconnectCapability("persisted-secret", null), null);
});

test("room end publishes its terminal state after peer media cleanup", async () => {
  const room = new ClipWebRoomSession({ invite: { sessionId: "room" }, identity: {}, iceServers: [] });
  const events = [];
  room.media.addEventListener("change", () => events.push("media-cleanup"));
  room.addEventListener("state", (event) => events.push(event.detail.state));
  room.peers.set("remote", { close() { room.media.changed("tracks"); } });
  await room.receiveWire(JSON.stringify({ version: 4, type: "room-ended", reason: "Finished" }));
  assert.equal(events.at(-1), "ended");
  assert.equal(room.closed, true);
  room.setState("connected");
  room.fail(new Error("late peer callback"));
  assert.equal(room.state, "ended");
});

test("explicit leave is terminal and rejects late room state callbacks", () => {
  const room = new ClipWebRoomSession({ invite: { sessionId: "room" }, identity: {}, iceServers: [] });
  room.close();
  assert.equal(room.state, "left");
  assert.equal(room.setState("reconnecting"), false);
  assert.equal(room.state, "left");
});

test("copied session storage receives a distinct active-tab identity while reload preserves one", async () => {
  class MemoryStorage {
    constructor(source = null) { this.values = new Map(source?.values ?? []); }
    get length() { return this.values.size; }
    key(index) { return [...this.values.keys()][index] ?? null; }
    getItem(key) { return this.values.get(key) ?? null; }
    setItem(key, value) { this.values.set(key, String(value)); }
    removeItem(key) { this.values.delete(key); }
  }
  class ChannelHub {
    constructor() { this.channels = new Map(); }
    factory = (name) => {
      const listeners = new Set();
      const channel = {
        addEventListener: (_type, listener) => listeners.add(listener),
        removeEventListener: (_type, listener) => listeners.delete(listener),
        postMessage: (data) => queueMicrotask(() => {
          for (const peer of this.channels.get(name) ?? []) {
            if (peer !== channel) for (const listener of peer.listeners) listener({ data });
          }
        }),
        close: () => this.channels.get(name)?.delete(channel),
        listeners,
      };
      if (!this.channels.has(name)) this.channels.set(name, new Set());
      this.channels.get(name).add(channel);
      return channel;
    };
  }
  const wait = () => new Promise((resolve) => setImmediate(resolve));
  const hub = new ChannelHub();
  const originalStorage = new MemoryStorage();
  const original = await resolveBrowserTabIdentity({
    storageKey: "room", displayName: "Original", storage: originalStorage,
    channelFactory: hub.factory, wait,
  });
  originalStorage.setItem("room.reconnect", "copied-reconnect");
  originalStorage.setItem("room.pair.example", "copied-pair");
  const copiedStorage = new MemoryStorage(originalStorage);
  const duplicate = await resolveBrowserTabIdentity({
    storageKey: "room", displayName: "Duplicate", storage: copiedStorage,
    channelFactory: hub.factory, wait,
  });
  assert.notEqual(duplicate.identity.descriptor.participantID, original.identity.descriptor.participantID);
  assert.equal(copiedStorage.getItem("room.reconnect"), null);
  assert.equal(copiedStorage.getItem("room.pair.example"), null);
  assert.equal(originalStorage.getItem("room.reconnect"), "copied-reconnect");

  original.claim.close();
  const reloaded = await resolveBrowserTabIdentity({
    storageKey: "room", displayName: "Reloaded", storage: originalStorage,
    navigationType: "reload", channelFactory: hub.factory, wait,
  });
  assert.equal(reloaded.identity.descriptor.participantID, original.identity.descriptor.participantID);
  duplicate.claim.close(); reloaded.claim.close();
});

test("transient reconnect failures retry with bounded backoff while permanent failures stop", async () => {
  const transient = new ClipWebRoomSession({
    invite: { sessionId: "room" }, identity: {}, iceServers: [],
    reconnectPolicy: { maximumAttempts: 2, delay: () => 0 },
  });
  transient.localHandle = "member";
  transient.reconnectCapability = "capability";
  let attempts = 0;
  transient.obtainReconnectTicket = async () => {
    attempts += 1;
    throw new ClipWebReconnectError("offline", true);
  };
  await transient.connect();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(attempts, 3);
  assert.equal(transient.state, "reconnect-failed");
  transient.close(false);

  const permanent = new ClipWebRoomSession({ invite: { sessionId: "room" }, identity: {}, iceServers: [] });
  permanent.localHandle = "member";
  permanent.reconnectCapability = "capability";
  permanent.obtainReconnectTicket = async () => { throw new ClipWebReconnectError("rejected", false); };
  await permanent.connect();
  assert.equal(permanent.state, "reconnect-failed");
  assert.equal(permanent.reconnectTimer, null);
  permanent.close(false);
});

test("same-revision roster recovery recreates only interrupted peer edges", async () => {
  const room = new ClipWebRoomSession({ invite: { sessionId: "room" }, identity: {}, iceServers: [] });
  const handle = "AQEBAQEBAQEBAQEBAQEBAQ";
  const roster = { revision: 3, creatorHandle: handle, members: [{ handle, descriptor: "sealed", connected: true }] };
  room.rosterRevision = 3;
  room.lastRosterJSON = JSON.stringify(roster);
  let recoveryCalls = 0;
  room.recoverInterruptedPeerEdges = async () => { recoveryCalls += 1; };
  await room.applyRoster(roster, { recoverInterruptedPeers: true });
  assert.equal(recoveryCalls, 1);

  room.localHandle = "local";
  const interrupted = { handle: "remote", connected: true, descriptor: { participantID: "remote-id" } };
  room.members = new Map([["remote", interrupted]]);
  let oldClosed = 0;
  room.peers = new Map([["remote", { needsRecreationAfterSignalingReconnect: () => true, close: () => { oldClosed += 1; } }]]);
  let newStarted = 0;
  room.createPeer = async () => ({
    remoteParticipantID: "remote-id",
    start: async () => { newStarted += 1; },
    needsRecreationAfterSignalingReconnect: () => false,
    close() {},
  });
  await ClipWebRoomSession.prototype.recoverInterruptedPeerEdges.call(room);
  assert.equal(oldClosed, 1);
  assert.equal(newStarted, 1);
});

test("roster topology maintains one peer per remote member across A+B+Web and A+B+C+Web", async () => {
  const room = new ClipWebRoomSession({ invite: { sessionId: "room" }, identity: {}, iceServers: [] });
  room.localHandle = "web";
  room.rosterRevision = 1;
  const native = (handle) => ({ handle, connected: true, descriptor: { participantID: `${handle}-id`, clientKind: "nativeApp", capabilityProfile: "nativeV1" } });
  const browser = (handle) => ({ handle, connected: true, descriptor: { participantID: `${handle}-id`, clientKind: "webViewer", capabilityProfile: "webViewerV1" } });
  const local = browser("web");
  const created = [];
  room.createPeer = async (member) => {
    const peer = {
      member,
      remoteParticipantID: member.descriptor.participantID,
      started: 0,
      updates: 0,
      closed: 0,
      async start() { this.started += 1; },
      async updateRosterRevision() { this.updates += 1; },
      needsRecreationAfterSignalingReconnect: () => false,
      close() { this.closed += 1; },
    };
    created.push(peer);
    return peer;
  };

  const A = native("A");
  const B = browser("B");
  await room.reconcilePeerTopology([A, B, local]);
  assert.deepEqual([...room.peers.keys()].sort(), ["A", "B"]);
  const peerA = room.peers.get("A");
  const peerB = room.peers.get("B");
  assert.equal(peerB.member.descriptor.clientKind, "webViewer");

  const C = native("C");
  await room.reconcilePeerTopology([A, B, C, local]);
  assert.deepEqual([...room.peers.keys()].sort(), ["A", "B", "C"]);
  assert.equal(room.peers.get("A"), peerA);
  assert.equal(room.peers.get("B"), peerB);
  const peerC = room.peers.get("C");

  await room.reconcilePeerTopology([A, { ...B, connected: false }, C, local]);
  assert.deepEqual([...room.peers.keys()].sort(), ["A", "C"]);
  assert.equal(room.peers.get("A"), peerA);
  assert.equal(room.peers.get("C"), peerC);
  assert.equal(peerB.closed, 1);
  assert.equal(created.length, 3);
});

test("browser-browser edge publishes no tracks and keeps the ordered control data channel", async () => {
  const prior = globalThis.RTCPeerConnection;
  let connection;
  class FakePeerConnection {
    constructor() {
      connection = this;
      this.signalingState = "stable";
      this.connectionState = "new";
      this.transceivers = [];
      this.channels = [];
    }
    addEventListener() {}
    addTransceiver(kind, options) { this.transceivers.push({ kind, ...options }); }
    createDataChannel(label, options) {
      const channel = {
        label, ordered: options.ordered, maxRetransmits: null, maxPacketLifeTime: null,
        readyState: "connecting", addEventListener() {}, close() {},
      };
      this.channels.push(channel);
      return channel;
    }
    async createOffer() { return { type: "offer", sdp: "v=0\r\n" }; }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const sent = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "remote-web", clientKind: "webViewer", capabilityProfile: "webViewerV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
    sendSignal: async (envelope) => sent.push(envelope), localParticipantID: "local-web", sessionId: "room",
  });
  try {
    await peer.start();
    assert.equal(connection.transceivers.filter((entry) => entry.kind === "video").length, 4);
    assert.equal(connection.transceivers.filter((entry) => entry.kind === "audio").length, 1);
    assert.equal(connection.transceivers.every((entry) => entry.direction === "recvonly"), true);
    assert.equal(connection.channels[0].label, "clip-native-control-v3");
    assert.equal(connection.channels[0].ordered, true);
    assert.equal(sent.length, 1);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = prior;
  }
});

test("browser receiver enforces the remote Web receive-only capability profile", () => {
  const prior = globalThis.RTCPeerConnection;
  const connections = [];
  class FakePeerConnection {
    constructor() {
      this.listeners = new Map();
      this.connectionState = "new";
      this.signalingState = "stable";
      connections.push(this);
    }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    getTransceivers() { return []; }
    close() { this.closed = true; }
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const owner = "AgICAgICAgICAgICAgICAg";
  const sourceID = "AQEBAQEBAQEBAQEBAQEBAQ";
  const makePeer = () => {
    const calls = { snapshots: 0, videos: 0, audios: 0, cursors: 0, states: [], clears: 0 };
    const mediaStore = {
      applySourceSnapshot() { calls.snapshots += 1; },
      applySourceCursor() { calls.cursors += 1; },
      setVideoTrack() { calls.videos += 1; },
      setAudioTrack() { calls.audios += 1; },
      setPeerState(...args) { calls.states.push(args); },
      clearRemoteMedia() { calls.clears += 1; },
    };
    const peer = new ClipWebMeshPeer({
      context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
      remoteMember: { descriptor: { participantID: owner, clientKind: "webViewer", capabilityProfile: "webViewerV1" } },
      pairChannel: { inboundSequence: 0, outboundSequence: 0 },
      iceServers: [], mediaStore, sendSignal: async () => {}, localParticipantID: "local", sessionId: "room",
    });
    return { peer, calls, connection: connections.at(-1) };
  };
  try {
    const honest = makePeer();
    honest.peer.receiveControl(JSON.stringify(emptyWebSourceSnapshot({
      sessionId: "room", participantID: owner, sourceRevision: 1,
    })));
    assert.equal(honest.calls.snapshots, 1);
    assert.equal(honest.peer.closed, false);

    const metadataViolation = makePeer();
    metadataViolation.peer.receiveControl(JSON.stringify({
      version: 4, type: "source-snapshot", payload: {
        version: 3, sessionId: "room", membershipRevision: 1,
        ownerParticipantId: owner, sourceRevision: 1,
        sources: [{
          key: { ownerParticipantId: owner, sourceInstanceId: sourceID },
          descriptor: { sourceInstanceId: sourceID, stream: {
            id: "stream", mediaTrackId: "track", active: true, focused: true,
            appName: "App", windowName: "Window", width: 800, height: 600,
            sourcePointWidth: 800, sourcePointHeight: 600, order: 0,
          } },
        }],
      },
    }));
    assert.equal(metadataViolation.calls.snapshots, 0);
    assert.equal(metadataViolation.peer.closed, true);
    assert.equal(metadataViolation.calls.states.at(-1)[2].capabilityViolation, true);

    for (const type of ["source-cursor", "collaboration", "friendship"]) {
      const violation = makePeer();
      violation.peer.receiveControl(JSON.stringify({ version: 4, type, payload: {} }));
      assert.equal(violation.peer.closed, true, `${type} must retire only its Web peer edge`);
      assert.equal(violation.calls.cursors, 0);
    }

    const mediaViolation = makePeer();
    let stopped = 0;
    mediaViolation.connection.listeners.get("track")({
      track: { id: "forbidden", kind: "video", stop() { stopped += 1; } },
      transceiver: { mid: "0" }, receiver: {},
    });
    assert.equal(stopped, 1);
    assert.equal(mediaViolation.calls.videos, 0);
    assert.equal(mediaViolation.calls.audios, 0);
    assert.equal(mediaViolation.peer.closed, true);
  } finally {
    for (const connection of connections) connection.close();
    globalThis.RTCPeerConnection = prior;
  }
});

test("the serial queue preserves full async operation order after a failure", async () => {
  const queue = new ClipSerialQueue();
  const order = [];
  const first = queue.enqueue(async () => { order.push("first-start"); await Promise.resolve(); order.push("first-end"); });
  const failed = queue.enqueue(async () => { order.push("failed"); throw new Error("expected"); });
  const last = queue.enqueue(async () => { order.push("last"); });
  await first;
  await assert.rejects(failed, /expected/u);
  await last;
  assert.deepEqual(order, ["first-start", "first-end", "failed", "last"]);
});

test("ICE restart remains in native fixed pair epoch one", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; this.localDescription = null; this.listeners = new Map(); this.restartCount = 0; }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    restartIce() { this.restartCount += 1; }
    async createOffer(options) { return { type: "offer", sdp: options.iceRestart ? "restart" : "offer" }; }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  try {
    const sent = [];
    const peer = new ClipWebMeshPeer({
      context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
      remoteMember: { descriptor: { participantID: "remote" } },
      pairChannel: {
        inboundSequence: 0, outboundSequence: 0,
        async seal(payload) { this.outboundSequence += 1; return { payload, sequence: this.outboundSequence }; },
      },
      iceServers: [],
      mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
      sendSignal: async (envelope) => { sent.push(envelope.payload); },
      localParticipantID: "local", sessionId: "room",
    });
    await peer.restartICE();
    assert.equal(PAIR_EPOCH, 1);
    assert.equal(peer.epoch, 1);
    assert.equal(peer.connection.restartCount, 1);
    assert.equal(sent[0].epoch, 1);
  } finally {
    globalThis.RTCPeerConnection = prior;
  }
});

test("concurrent peer signals serialize encryption, send, decrypt, and handling", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; }
    addEventListener() {}
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  try {
    const sent = [];
    let outbound = 0;
    let inbound = 0;
    const pairChannel = {
      inboundSequence: 0, outboundSequence: 0,
      async seal(payload) {
        await new Promise((resolve) => setTimeout(resolve, payload.candidate.endsWith("0") ? 5 : 0));
        outbound += 1; this.outboundSequence = outbound;
        return { sequence: outbound, payload };
      },
      async open(envelope) {
        await new Promise((resolve) => setTimeout(resolve, envelope.sequence === 1 ? 5 : 0));
        inbound = envelope.sequence; this.inboundSequence = inbound;
        return envelope.payload;
      },
    };
    const peer = new ClipWebMeshPeer({
      context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
      remoteMember: { descriptor: { participantID: "remote" } }, pairChannel,
      iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
      sendSignal: async (envelope) => { await Promise.resolve(); sent.push(envelope); },
      localParticipantID: "local", sessionId: "room",
    });
    const candidates = Array.from({ length: 6 }, (_, index) => ({ type: "ice-candidate", epoch: 1, candidate: `candidate-${index}`, mediaId: "0", mediaLineIndex: 0 }));
    await Promise.all(candidates.map((payload) => peer.signal(payload)));
    assert.deepEqual(sent.map((entry) => entry.sequence), [1, 2, 3, 4, 5, 6]);
    assert.deepEqual(sent.map((entry) => entry.payload.candidate), candidates.map((entry) => entry.candidate));

    const received = [];
    peer.receiveSignal = async (payload) => { await Promise.resolve(); received.push(payload.candidate); };
    await Promise.all(sent.map((envelope) => peer.receiveEnvelope(envelope)));
    assert.deepEqual(received, candidates.map((entry) => entry.candidate));
  } finally {
    globalThis.RTCPeerConnection = prior;
  }
});

test("answerer requests one same-epoch renegotiation when its edge fails", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; this.connectionState = "new"; this.listeners = new Map(); }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  try {
    const sent = [];
    const peer = new ClipWebMeshPeer({
      context: { localHandle: "B", remoteHandle: "A", initialOfferer: "A" },
      remoteMember: { descriptor: { participantID: "remote" } },
      pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { this.outboundSequence += 1; return { payload }; } },
      iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
      sendSignal: async (envelope) => sent.push(envelope.payload), localParticipantID: "local", sessionId: "room",
    });
    peer.connection.connectionState = "failed";
    peer.connection.listeners.get("connectionstatechange")();
    peer.connection.listeners.get("connectionstatechange")();
    await peer.outboundSignalQueue.tail;
    assert.deepEqual(sent, [{ type: "renegotiation-request", epoch: 1 }]);
  } finally {
    globalThis.RTCPeerConnection = prior;
  }
});

test("canonical Web offerer applies an exact requested codec before one fresh offer", async () => {
  const priorConnection = globalThis.RTCPeerConnection;
  const priorReceiver = globalThis.RTCRtpReceiver;
  const preferences = [];
  class FakePeerConnection {
    constructor() {
      this.signalingState = "stable";
      this.connectionState = "connected";
      this.localDescription = null;
      this.video = {
        receiver: { track: { kind: "video" } },
        sender: { track: null },
        setCodecPreferences(value) { preferences.push(value); },
      };
    }
    addEventListener() {}
    getTransceivers() { return [this.video]; }
    async createOffer() { return { type: "offer", sdp: "v=0\r\n" }; }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  globalThis.RTCRtpReceiver = { getCapabilities: () => ({ codecs: [
    { mimeType: "video/VP8", clockRate: 90000 },
    { mimeType: "video/AV1", clockRate: 90000 },
  ] }) };
  const sent = [];
  const states = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "native", clientKind: "nativeApp", capabilityProfile: "nativeV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [],
    mediaStore: { setPeerState(...args) { states.push(args); }, clearUnsupportedEncoding() {}, clearRemoteMedia() {} },
    sendSignal: async (envelope) => sent.push(envelope.payload), localParticipantID: "web", sessionId: "room",
  });
  try {
    await peer.receiveSignal({ type: "codec-renegotiation-request", epoch: 1, codec: "av1" });
    assert.deepEqual(preferences, [[{ mimeType: "video/AV1", clockRate: 90000 }]]);
    assert.deepEqual(sent, [{ type: "offer", epoch: 1, sdp: "v=0\r\n" }]);
    assert.equal(states.length, 0);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = priorConnection;
    globalThis.RTCRtpReceiver = priorReceiver;
  }
});

test("canonical Web offerer reports an unsupported requested codec without choosing a fallback", async () => {
  const priorConnection = globalThis.RTCPeerConnection;
  const priorReceiver = globalThis.RTCRtpReceiver;
  let preferenceCalls = 0;
  class FakePeerConnection {
    constructor() {
      this.signalingState = "stable";
      this.connectionState = "connected";
      this.localDescription = null;
      this.video = {
        receiver: { track: { kind: "video" } }, sender: { track: null },
        setCodecPreferences() { preferenceCalls += 1; },
      };
    }
    addEventListener() {}
    getTransceivers() { return [this.video]; }
    async createOffer() { return { type: "offer", sdp: "v=0\r\n" }; }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  globalThis.RTCRtpReceiver = { getCapabilities: () => ({ codecs: [{ mimeType: "video/VP8" }] }) };
  const sent = [];
  const states = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "native", clientKind: "nativeApp", capabilityProfile: "nativeV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [],
    mediaStore: { setPeerState(...args) { states.push(args); }, clearRemoteMedia() {} },
    sendSignal: async (envelope) => sent.push(envelope.payload), localParticipantID: "web", sessionId: "room",
  });
  try {
    await peer.receiveSignal({ type: "codec-renegotiation-request", epoch: 1, codec: "av1" });
    assert.equal(preferenceCalls, 0);
    assert.equal(states.at(-1)[2].unsupportedEncoding, true);
    assert.equal(states.at(-1)[2].codec, "AV1");
    assert.deepEqual(sent, [{ type: "codec-renegotiation-rejected", epoch: 1, codec: "av1" }]);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = priorConnection;
    globalThis.RTCRtpReceiver = priorReceiver;
  }
});

test("Web answerer recovers supported to unsupported to supported without fallback", async () => {
  const priorConnection = globalThis.RTCPeerConnection;
  const priorReceiver = globalThis.RTCRtpReceiver;
  class FakePeerConnection {
    constructor() {
      this.signalingState = "stable";
      this.connectionState = "connected";
      this.localDescription = null;
      this.remoteDescription = null;
      this.remoteDescriptions = [];
    }
    addEventListener() {}
    getTransceivers() { return []; }
    async setRemoteDescription(value) {
      this.remoteDescription = value;
      this.remoteDescriptions.push(value);
    }
    async createAnswer() {
      return {
        type: "answer",
        sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n",
      };
    }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  globalThis.RTCRtpReceiver = {
    getCapabilities: () => ({ codecs: [{ mimeType: "video/VP8", clockRate: 90000 }] }),
  };
  const sent = [];
  const states = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "B", remoteHandle: "A", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "native", clientKind: "nativeApp", capabilityProfile: "nativeV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [],
    mediaStore: {
      setPeerState(...args) { states.push(args); },
      clearUnsupportedEncoding() {},
      clearRemoteMedia() {},
    },
    sendSignal: async (envelope) => sent.push(envelope.payload),
    localParticipantID: "web",
    sessionId: "room",
  });
  const offer = (codec, payload = 96) => ({
    type: "offer",
    epoch: 1,
    sdp: `v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF ${payload}\r\na=rtpmap:${payload} ${codec}/90000\r\n`,
  });
  try {
    await peer.receiveSignal(offer("VP8", 96));
    await peer.receiveSignal(offer("AV1", 97));
    await peer.receiveSignal(offer("VP8", 98));

    assert.deepEqual(sent.map((entry) => entry.type), [
      "answer",
      "codec-renegotiation-rejected",
      "answer",
    ]);
    assert.deepEqual(sent[1], {
      type: "codec-renegotiation-rejected",
      epoch: 1,
      codec: "av1",
    });
    assert.equal(peer.connection.remoteDescriptions.length, 2);
    assert.ok(peer.connection.remoteDescriptions.every((entry) => !entry.sdp.includes("AV1")));
    assert.equal(states.some((entry) => entry[2]?.unsupportedEncoding === true), true);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = priorConnection;
    globalThis.RTCRtpReceiver = priorReceiver;
  }
});

test("Web answerer rejects a known codec when applying its offer fails, then recovers", async () => {
  const priorConnection = globalThis.RTCPeerConnection;
  const priorReceiver = globalThis.RTCRtpReceiver;
  class FakePeerConnection {
    constructor() {
      this.signalingState = "stable";
      this.connectionState = "connected";
      this.localDescription = null;
      this.failNextRemoteDescription = true;
      this.applied = [];
    }
    addEventListener() {}
    getTransceivers() { return []; }
    async setRemoteDescription(value) {
      if (this.failNextRemoteDescription) {
        this.failNextRemoteDescription = false;
        throw new Error("browser rejected the SDP");
      }
      this.remoteDescription = value;
      this.applied.push(value);
    }
    async createAnswer() {
      return { type: "answer", sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n" };
    }
    async setLocalDescription(value) { this.localDescription = value; }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  globalThis.RTCRtpReceiver = {
    getCapabilities: () => ({ codecs: [{ mimeType: "video/VP8", clockRate: 90000 }] }),
  };
  const sent = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "B", remoteHandle: "A", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "native", clientKind: "nativeApp", capabilityProfile: "nativeV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [],
    mediaStore: { setPeerState() {}, clearUnsupportedEncoding() {}, clearRemoteMedia() {} },
    sendSignal: async (envelope) => sent.push(envelope.payload),
    localParticipantID: "web",
    sessionId: "room",
  });
  const vp8Offer = {
    type: "offer",
    epoch: 1,
    sdp: "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000\r\n",
  };
  try {
    await peer.receiveSignal(vp8Offer);
    await peer.receiveSignal(vp8Offer);
    assert.deepEqual(sent.map((entry) => entry.type), [
      "codec-renegotiation-rejected",
      "answer",
    ]);
    assert.equal(peer.connection.applied.length, 1);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = priorConnection;
    globalThis.RTCRtpReceiver = priorReceiver;
  }
});

test("deterministic pair roles reject offers and answers from the wrong side", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; this.connectionState = "new"; }
    addEventListener() {}
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const makePeer = (isOfferer) => new ClipWebMeshPeer({
    context: { localHandle: isOfferer ? "A" : "B", remoteHandle: isOfferer ? "B" : "A", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "remote" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0 },
    iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
    sendSignal: async () => {}, localParticipantID: "local", sessionId: "room",
  });
  try {
    await assert.rejects(makePeer(true).receiveSignal({ type: "offer", epoch: 1, sdp: "v=0" }), /deterministic answerer/u);
    await assert.rejects(makePeer(false).receiveSignal({ type: "answer", epoch: 1, sdp: "v=0" }), /deterministic offerer/u);
  } finally {
    globalThis.RTCPeerConnection = prior;
  }
});

test("control channel accepts only the ordered reliable native contract", () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection { addEventListener() {} close() {} }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "B", remoteHandle: "A", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "remote" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0 },
    iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
    sendSignal: async () => {}, localParticipantID: "local", sessionId: "room",
  });
  const channel = (overrides = {}) => ({
    label: "clip-native-control-v3", ordered: true, maxRetransmits: null, maxPacketLifeTime: null,
    closeCount: 0, close() { this.closeCount += 1; }, addEventListener() {}, ...overrides,
  });
  try {
    const unordered = channel({ ordered: false });
    peer.acceptControlChannel(unordered);
    assert.equal(unordered.closeCount, 1);
    const lossy = channel({ maxRetransmits: 0 });
    peer.acceptControlChannel(lossy);
    assert.equal(lossy.closeCount, 1);
    const valid = channel();
    peer.acceptControlChannel(valid);
    assert.equal(valid.closeCount, 0);
    assert.equal(peer.controlChannel, valid);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = prior;
  }
});

test("closed peers ignore late callbacks and signaling send failures mark an edge for recreation", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; this.connectionState = "connected"; this.listeners = new Map(); }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const states = [];
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "A", remoteHandle: "B", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "remote" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0, async seal(payload) { return { payload }; } },
    iceServers: [], mediaStore: { setPeerState(...args) { states.push(args); }, clearRemoteMedia() {} },
    sendSignal: async () => { throw new Error("socket unavailable"); }, localParticipantID: "local", sessionId: "room",
  });
  try {
    await assert.rejects(peer.signal({ type: "renegotiation-request", epoch: 1 }), /socket unavailable/u);
    assert.equal(peer.needsRecreationAfterSignalingReconnect(), true);
    peer.close(false);
    peer.connection.listeners.get("connectionstatechange")();
    assert.equal(states.length, 0);
  } finally {
    globalThis.RTCPeerConnection = prior;
  }
});

test("decrypted pair payloads enforce native closed shapes and bounds", () => {
  assert.equal(validatePairPayload({ type: "offer", epoch: 1, sdp: "v=0" }).type, "offer");
  assert.equal(validatePairPayload({ type: "ice-candidate", epoch: 1, candidate: "", mediaId: null, mediaLineIndex: null }).type, "ice-candidate");
  assert.equal(validatePairPayload({ type: "codec-renegotiation-request", epoch: 1, codec: "av1" }).codec, "av1");
  assert.equal(validatePairPayload({ type: "codec-renegotiation-rejected", epoch: 1, codec: "av1" }).codec, "av1");
  assert.throws(() => validatePairPayload({ type: "offer", epoch: 2, sdp: "v=0" }), /SDP/u);
  assert.throws(() => validatePairPayload({ type: "answer", epoch: 1, sdp: "", extra: true }), /shape/u);
  assert.throws(() => validatePairPayload({ type: "ice-candidate", epoch: 1, candidate: "x".repeat(4097) }), /candidate/u);
  assert.throws(() => validatePairPayload({ type: "close", epoch: 1 }), /shape/u);
  assert.throws(() => validatePairPayload({ type: "codec-renegotiation-request", epoch: 1 }), /shape/u);
  assert.throws(() => validatePairPayload({ type: "codec-renegotiation-request", epoch: 1, codec: "AV1" }), /codec/u);
  assert.throws(() => validatePairPayload({ type: "codec-renegotiation-request", epoch: 1, codec: "av1", fallback: "vp8" }), /shape/u);
  assert.throws(() => validatePairPayload({ type: "codec-renegotiation-rejected", epoch: 1, codec: "av1", fallback: "vp8" }), /shape/u);
});

test("one authenticated peer cannot queue unbounded ICE candidates", async () => {
  const prior = globalThis.RTCPeerConnection;
  class FakePeerConnection {
    constructor() { this.signalingState = "stable"; this.connectionState = "new"; this.remoteDescription = null; }
    addEventListener() {}
    close() {}
  }
  globalThis.RTCPeerConnection = FakePeerConnection;
  const peer = new ClipWebMeshPeer({
    context: { localHandle: "B", remoteHandle: "A", initialOfferer: "A" },
    remoteMember: { descriptor: { participantID: "remote", clientKind: "nativeApp", capabilityProfile: "nativeV1" } },
    pairChannel: { inboundSequence: 0, outboundSequence: 0 },
    iceServers: [], mediaStore: { setPeerState() {}, clearRemoteMedia() {} },
    sendSignal: async () => {}, localParticipantID: "local", sessionId: "room",
  });
  try {
    const candidate = { type: "ice-candidate", epoch: 1, candidate: "candidate", mediaId: "0", mediaLineIndex: 0 };
    for (let index = 0; index < 256; index += 1) await peer.receiveSignal(candidate);
    assert.equal(peer.pendingCandidates.length, 256);
    await assert.rejects(peer.receiveSignal(candidate), /exceeded 256 ICE candidates/u);
  } finally {
    peer.close(false);
    globalThis.RTCPeerConnection = prior;
  }
});

test("disconnect cleanup retains authoritative roster membership and web badge", () => {
  const media = new ClipWebMediaStore("room");
  media.setParticipants([{ handle: "remote", connected: false, descriptor: {
    participantID: "browser", displayName: "Browser", deviceName: "Web",
    clientKind: "webViewer", capabilityProfile: "webViewerV1",
  } }], "creator", "local");
  media.clearRemoteMedia("browser");
  assert.equal(media.participants.get("browser").descriptor.clientKind, "webViewer");
  assert.equal(media.participants.get("browser").connected, false);
  assert.deepEqual(participantConnectionState(media.participants.get("browser"), { state: "p2p" }), { state: "disconnected" });
});

test("receiver reconciliation replaces Safari browser track ID with native manifest ID", () => {
  const media = new ClipWebMediaStore("room");
  const track = { id: "safari-rewritten", kind: "video", addEventListener() {} };
  media.setVideoTrack("native", track, track.id);
  media.setVideoTrack("native", track, "native-manifest-track");
  assert.equal(media.videoTracks.has("safari-rewritten"), false);
  assert.equal(media.videoTracks.get("native-manifest-track").track, track);
  const count = media.videoTracks.size;
  media.setVideoTrack("native", track, "native-manifest-track");
  assert.equal(media.videoTracks.size, count);
});
