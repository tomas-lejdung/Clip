import assert from "node:assert/strict";
import test from "node:test";

import {
  AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS,
  configureWebReceiverLatency,
} from "../assets/clip-web-receiver.js";

test("video receivers stay at the live edge", () => {
  const receiver = { jitterBufferTarget: 80, playoutDelayHint: 0.25 };

  assert.equal(configureWebReceiverLatency(receiver, "video"), true);
  assert.equal(receiver.jitterBufferTarget, 0);
  assert.equal(receiver.playoutDelayHint, 0);
});

test("audio keeps a small jitter reservoir without overriding playout delay", () => {
  const receiver = { jitterBufferTarget: 0, playoutDelayHint: 0.4 };

  assert.equal(configureWebReceiverLatency(receiver, "audio"), true);
  assert.equal(
    receiver.jitterBufferTarget,
    AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS,
  );
  assert.equal(receiver.playoutDelayHint, 0.4);
});

test("optional or read-only receiver hints never fail a room link", () => {
  assert.equal(configureWebReceiverLatency({}, "video"), true);
  assert.equal(configureWebReceiverLatency(null, "video"), false);
  assert.equal(configureWebReceiverLatency({}, "data"), false);

  const receiver = { playoutDelayHint: 0.4 };
  Object.defineProperty(receiver, "jitterBufferTarget", {
    configurable: true,
    get: () => 50,
    set: () => { throw new TypeError("read only"); },
  });
  assert.equal(configureWebReceiverLatency(receiver, "video"), true);
  assert.equal(receiver.playoutDelayHint, 0);
});
