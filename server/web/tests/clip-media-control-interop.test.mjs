import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  emptyWebSourceSnapshot,
  validateSourceCursor,
  validateSourceSnapshot,
} from "../assets/clip-viewer-state.js";

const fixtureURL = new URL(
  "../../../Packages/ClipLiveShare/Tests/Fixtures/web-media-control.json",
  import.meta.url,
);
const fixture = JSON.parse(await readFile(fixtureURL, "utf8"));

test("browser consumes the frozen Swift native source snapshot", () => {
  const message = fixture.nativeSourceSnapshot;
  const snapshot = validateSourceSnapshot(message, {
    sessionId: "web-media-control-fixture",
    ownerParticipantID: "EREREREREREREREREREREQ",
  });
  assert.equal(snapshot.revision, 7);
  assert.equal(snapshot.membershipRevision, 1);
  assert.deepEqual(snapshot.sources, [{
    key: "EREREREREREREREREREREQ:MzMzMzMzMzMzMzMzMzMzMw",
    ownerParticipantID: "EREREREREREREREREREREQ",
    sourceInstanceID: "MzMzMzMzMzMzMzMzMzMzMw",
    streamID: "native-stream-0",
    mediaTrackID: "native-video-0",
    active: true,
    focused: true,
    appName: "Fixture App",
    windowName: "Fixture Window",
    width: 2560,
    height: 1440,
    sourcePointWidth: 1280,
    sourcePointHeight: 720,
    order: 0,
  }]);
});

test("browser empty publication exactly matches the frozen Swift snapshot", () => {
  assert.deepEqual(
    emptyWebSourceSnapshot({
      sessionId: "web-media-control-fixture",
      participantID: "IiIiIiIiIiIiIiIiIiIiIg",
      sourceRevision: 3,
    }),
    fixture.webEmptySourceSnapshot,
  );
});

test("browser consumes the frozen Swift source cursor", () => {
  assert.deepEqual(
    validateSourceCursor(fixture.nativeSourceCursor, {
      sessionId: "web-media-control-fixture",
      ownerParticipantID: "EREREREREREREREREREREQ",
    }),
    {
      key: "EREREREREREREREREREREQ:MzMzMzMzMzMzMzMzMzMzMw",
      streamID: "native-stream-0",
      sequence: 9,
      position: { x: 0.75, y: 0.25 },
    },
  );
});
