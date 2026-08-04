export const AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS = 60;

/**
 * Keeps browser playback at the same live-edge policy as Clip's original Web
 * viewer. Video should not build an adaptive playout reservoir: a screen-share
 * frame that arrives late is less useful than the current frame. System audio
 * retains a small buffer so scheduler/network jitter does not cause dropouts.
 *
 * These are optional browser hints. Safari and Chromium expose slightly
 * different writable shapes, so an unsupported/read-only property must never
 * make an otherwise healthy P2P link fail.
 */
export function configureWebReceiverLatency(receiver, kind) {
  if (!receiver || (kind !== "video" && kind !== "audio")) return false;

  if (kind === "audio") {
    setOptionalReceiverHint(
      receiver,
      "jitterBufferTarget",
      AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS,
    );
    return true;
  }

  // The hints are independent. Safari may expose one as read-only while a
  // Chromium release supports the other, so one rejected assignment must not
  // suppress the remaining live-edge request.
  setOptionalReceiverHint(receiver, "jitterBufferTarget", 0);
  setOptionalReceiverHint(receiver, "playoutDelayHint", 0);
  return true;
}

function setOptionalReceiverHint(receiver, property, value) {
  if (!(property in receiver)) return;
  try {
    receiver[property] = value;
  } catch {
    // Optional browser hint. A read-only implementation must not fail media.
  }
}
