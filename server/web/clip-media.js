export const AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS = 60;
export const OPUS_SYSTEM_AUDIO_PARAMETERS = Object.freeze({
  stereo: "1",
  "sprop-stereo": "1",
  maxaveragebitrate: "128000",
  usedtx: "0",
});

const MEDIA_KINDS = new Set(["audio", "video"]);

/**
 * Applies Clip's receiver latency policy without turning the audio jitter
 * buffer into a zero-margin video buffer. Audio needs a small reservoir for
 * packet and scheduler jitter; video is allowed to prefer the live edge.
 */
export function configureReceiverLatency(receiver, kind) {
  if (!receiver || !MEDIA_KINDS.has(kind)) return false;

  try {
    if (kind === "audio") {
      if ("jitterBufferTarget" in receiver) {
        receiver.jitterBufferTarget = AUDIO_JITTER_BUFFER_TARGET_MILLISECONDS;
      }
      // Deliberately preserve the browser's audio playoutDelayHint. Forcing it
      // to zero can make the audio renderer underrun even on a healthy route.
      return true;
    }

    if ("jitterBufferTarget" in receiver) receiver.jitterBufferTarget = 0;
    if ("playoutDelayHint" in receiver) receiver.playoutDelayHint = 0;
    return true;
  } catch {
    // Receiver hints are optional and some browsers expose a read-only shape.
    // WebRTC's adaptive defaults remain safe when a hint cannot be assigned.
    return false;
  }
}

function normalizedOpusParameters(value) {
  const required = new Map(Object.entries(OPUS_SYSTEM_AUDIO_PARAMETERS));
  const result = [];
  const seen = new Set();

  for (const component of String(value ?? "").split(";")) {
    const trimmed = component.trim();
    if (!trimmed) continue;
    const separator = trimmed.indexOf("=");
    const name = (separator < 0 ? trimmed : trimmed.slice(0, separator))
      .trim()
      .toLowerCase();
    if (!name || seen.has(name)) continue;
    seen.add(name);
    if (required.has(name)) {
      result.push(`${name}=${required.get(name)}`);
    } else {
      result.push(trimmed);
    }
  }

  for (const [name, parameterValue] of required) {
    if (!seen.has(name)) result.push(`${name}=${parameterValue}`);
  }
  return result.join(";");
}

/**
 * Makes a browser answer explicitly accept stereo, music-quality Opus. WebRTC
 * otherwise commonly answers Opus as a mono, speech-oriented 32 kbps stream
 * even though `opus/48000/2` appears in the RTP map.
 */
export function normalizeOpusSystemAudioSDP(sdp) {
  if (typeof sdp !== "string" || sdp.length === 0) return sdp;
  const newline = sdp.includes("\r\n") ? "\r\n" : "\n";
  const hadTrailingNewline = /\r?\n$/u.test(sdp);
  const lines = sdp.split(/\r?\n/u);
  if (hadTrailingNewline) lines.pop();

  for (let sectionStart = 0; sectionStart < lines.length; ) {
    if (!lines[sectionStart].startsWith("m=")) {
      sectionStart += 1;
      continue;
    }
    let sectionEnd = sectionStart + 1;
    while (sectionEnd < lines.length && !lines[sectionEnd].startsWith("m=")) {
      sectionEnd += 1;
    }
    if (!lines[sectionStart].startsWith("m=audio ")) {
      sectionStart = sectionEnd;
      continue;
    }

    const opusPayloads = [];
    for (let index = sectionStart + 1; index < sectionEnd; index += 1) {
      const match = /^a=rtpmap:(\d+)\s+opus\/48000(?:\/2)?\s*$/iu.exec(
        lines[index],
      );
      if (match) opusPayloads.push(match[1]);
    }

    for (const payload of opusPayloads) {
      const prefix = `a=fmtp:${payload}`;
      let fmtpIndex = -1;
      for (let index = sectionStart + 1; index < sectionEnd; index += 1) {
        if (
          lines[index] === prefix ||
          lines[index].startsWith(`${prefix} `)
        ) {
          fmtpIndex = index;
          break;
        }
      }
      if (fmtpIndex >= 0) {
        const parameters = lines[fmtpIndex].slice(prefix.length).trim();
        lines[fmtpIndex] = `${prefix} ${normalizedOpusParameters(parameters)}`;
      } else {
        const rtpmapIndex = lines.findIndex(
          (line, index) =>
            index > sectionStart &&
            index < sectionEnd &&
            new RegExp(`^a=rtpmap:${payload}\\s`, "iu").test(line),
        );
        if (rtpmapIndex < 0) continue;
        lines.splice(
          rtpmapIndex + 1,
          0,
          `${prefix} ${normalizedOpusParameters("")}`,
        );
        sectionEnd += 1;
      }
    }
    sectionStart = sectionEnd;
  }

  return lines.join(newline) + (hadTrailingNewline ? newline : "");
}

/** A new viewer starts muted; only an explicit stored choice may unmute it. */
export function initialAudioMuted(storedValue) {
  return storedValue === "0" ? false : true;
}

function optionalCounter(value) {
  return Number.isFinite(value) && value >= 0 ? value : null;
}

function optionalSignedCounter(value) {
  return Number.isFinite(value) ? value : null;
}

function monotonicDelta(current, previous) {
  if (current === null || previous === null || current < previous) return null;
  return current - previous;
}

function percentage(numerator, denominator) {
  if (numerator === null || denominator === null || denominator <= 0) return null;
  return Math.max(0, Math.min(100, (numerator / denominator) * 100));
}

/**
 * Converts one inbound audio RTCStats report into a stable, serializable debug
 * snapshot. `baseline` is the previous snapshot's private `_baseline` value.
 * Interval fields remain null when a browser omits a counter or resets an RTP
 * stream, rather than presenting a reset as packet loss or concealment.
 */
export function inboundAudioDiagnostics(report, baseline = null) {
  if (!report || report.type !== "inbound-rtp" || report.kind !== "audio") {
    return null;
  }

  const current = {
    timestamp: optionalCounter(report.timestamp),
    bytesReceived: optionalCounter(report.bytesReceived),
    packetsReceived: optionalCounter(report.packetsReceived),
    packetsLost: optionalSignedCounter(report.packetsLost),
    totalSamplesReceived: optionalCounter(report.totalSamplesReceived),
    concealedSamples: optionalCounter(report.concealedSamples),
    silentConcealedSamples: optionalCounter(report.silentConcealedSamples),
    concealmentEvents: optionalCounter(report.concealmentEvents),
    insertedSamplesForDeceleration: optionalCounter(
      report.insertedSamplesForDeceleration,
    ),
    removedSamplesForAcceleration: optionalCounter(
      report.removedSamplesForAcceleration,
    ),
    jitterBufferDelay: optionalCounter(report.jitterBufferDelay),
    jitterBufferEmittedCount: optionalCounter(report.jitterBufferEmittedCount),
  };

  const previous = baseline && typeof baseline === "object" ? baseline : {};
  const durationMilliseconds =
    current.timestamp !== null &&
    optionalCounter(previous.timestamp) !== null &&
    current.timestamp > previous.timestamp
      ? current.timestamp - previous.timestamp
      : null;
  const packetsReceivedDelta = monotonicDelta(
    current.packetsReceived,
    optionalCounter(previous.packetsReceived),
  );
  const packetsLostDelta = monotonicDelta(
    current.packetsLost,
    optionalSignedCounter(previous.packetsLost),
  );
  const totalSamplesDelta = monotonicDelta(
    current.totalSamplesReceived,
    optionalCounter(previous.totalSamplesReceived),
  );
  const concealedSamplesDelta = monotonicDelta(
    current.concealedSamples,
    optionalCounter(previous.concealedSamples),
  );
  const silentConcealedSamplesDelta = monotonicDelta(
    current.silentConcealedSamples,
    optionalCounter(previous.silentConcealedSamples),
  );
  const concealmentEventsDelta = monotonicDelta(
    current.concealmentEvents,
    optionalCounter(previous.concealmentEvents),
  );
  const insertedSamplesDelta = monotonicDelta(
    current.insertedSamplesForDeceleration,
    optionalCounter(previous.insertedSamplesForDeceleration),
  );
  const removedSamplesDelta = monotonicDelta(
    current.removedSamplesForAcceleration,
    optionalCounter(previous.removedSamplesForAcceleration),
  );
  const jitterBufferDelayDelta = monotonicDelta(
    current.jitterBufferDelay,
    optionalCounter(previous.jitterBufferDelay),
  );
  const jitterBufferEmittedDelta = monotonicDelta(
    current.jitterBufferEmittedCount,
    optionalCounter(previous.jitterBufferEmittedCount),
  );

  const lossDenominator =
    packetsReceivedDelta === null || packetsLostDelta === null
      ? null
      : packetsReceivedDelta + Math.max(0, packetsLostDelta);
  const averageJitterBufferDelayMilliseconds =
    jitterBufferDelayDelta !== null &&
    jitterBufferEmittedDelta !== null &&
    jitterBufferEmittedDelta > 0
      ? (jitterBufferDelayDelta / jitterBufferEmittedDelta) * 1000
      : null;

  return {
    trackIdentifier:
      typeof report.trackIdentifier === "string" ? report.trackIdentifier : null,
    codecId: typeof report.codecId === "string" ? report.codecId : null,
    jitterMilliseconds:
      Number.isFinite(report.jitter) && report.jitter >= 0
        ? report.jitter * 1000
        : null,
    audioLevel:
      Number.isFinite(report.audioLevel) && report.audioLevel >= 0
        ? report.audioLevel
        : null,
    bytesReceived: current.bytesReceived,
    packetsReceived: current.packetsReceived,
    packetsLost: current.packetsLost,
    totalSamplesReceived: current.totalSamplesReceived,
    concealedSamples: current.concealedSamples,
    silentConcealedSamples: current.silentConcealedSamples,
    concealmentEvents: current.concealmentEvents,
    insertedSamplesForDeceleration: current.insertedSamplesForDeceleration,
    removedSamplesForAcceleration: current.removedSamplesForAcceleration,
    interval: {
      durationMilliseconds,
      packetLossPercent: percentage(packetsLostDelta, lossDenominator),
      concealedSamples: concealedSamplesDelta,
      silentConcealedSamples: silentConcealedSamplesDelta,
      concealmentEvents: concealmentEventsDelta,
      concealedSamplePercent: percentage(
        concealedSamplesDelta,
        totalSamplesDelta,
      ),
      insertedSamplesForDeceleration: insertedSamplesDelta,
      removedSamplesForAcceleration: removedSamplesDelta,
      averageJitterBufferDelayMilliseconds,
    },
    _baseline: current,
  };
}

/** Returns the public part of a diagnostic without its next-poll baseline. */
export function publicAudioDiagnostics(diagnostic) {
  if (!diagnostic) return null;
  const { _baseline: _, ...publicValue } = diagnostic;
  return publicValue;
}
