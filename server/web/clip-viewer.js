import {
  assertInnerMessage,
  canonicalManifest,
  canonicalProtocolFailure,
  canonicalSystemAudioState,
  CLIP_PROTOCOL_VERSION,
  ClipProtocolError,
  createAuthProof,
  createInnerProtocolFailure,
  createViewerKeyPair,
  decodeBase64URL,
  deriveRouteKeys,
  encodeBase64URL,
  EncryptedRoute,
  fillPathTemplate,
  isOpaqueIdentifier,
  isOptionalText,
  isRequiredText,
  MAX_ICE_CANDIDATE_BYTES,
  MAX_INNER_MESSAGE_BYTES,
  MAX_SESSION_DESCRIPTION_BYTES,
  normalizeAccessCode,
  normalizeRoom,
  parseViewerFragment,
  PeerGenerationGuard,
  validateCapabilities,
  utf8Length,
  websocketURL,
} from "./clip-protocol.js";
import {
  configureReceiverLatency,
  inboundAudioDiagnostics,
  initialAudioMuted,
  normalizeOpusSystemAudioSDP,
  publicAudioDiagnostics,
} from "./clip-media.js";

// Elements
const mainVideo = document.getElementById("main-video");
const mainVideoContainer = document.getElementById(
  "main-video-container",
);
const thumbnailsBar = document.getElementById("thumbnails-bar");
const statusBar = document.getElementById("status-bar");
const statusDot = document.getElementById("status-dot");
const statusText = document.getElementById("status-text");
const roomCodeEl = document.getElementById("room-code");
const waitingEl = document.getElementById("waiting");
const waitingTitle = document.getElementById("waiting-title");
const waitingSubtitle = document.getElementById("waiting-subtitle");
const waitingRoom = document.getElementById("waiting-room");
const controlBar = document.getElementById("control-bar");
const shortcutsHelp = document.getElementById("shortcuts-help");
const statsPanel = document.getElementById("stats-panel");
const streamStats = document.getElementById("stream-stats");
const streamCountEl = document.getElementById("stream-count");
const streamCountText = document.getElementById("stream-count-text");
const systemAudio = document.getElementById("system-audio");
const audioButton = document.getElementById("btn-audio");
const audioVolume = document.getElementById("audio-volume");
const audioUnlock = document.getElementById("audio-unlock");

// Layout elements
const videoGrid = document.getElementById("video-grid");
const layoutSelector = document.getElementById("layout-selector");
const proportionalToggle = document.getElementById("proportional-toggle");
const proportionalSwitch = document.getElementById("proportional-switch");
const followToggle = document.getElementById("follow-toggle");
const followSwitch = document.getElementById("follow-switch");
const layoutDivider = document.getElementById("layout-divider");
const panZoomContainer = document.getElementById("pan-zoom-container");
const panZoomContent = document.getElementById("pan-zoom-content");
const minimap = document.getElementById("minimap");
const minimapCanvas = document.getElementById("minimap-canvas");
const minimapViewport = document.getElementById("minimap-viewport");
const videoRow = document.getElementById("video-row");
const rowMinimap = document.getElementById("row-minimap");

// State
let roomCode;
let viewerFragment;
let ws;
let pc;
const peerGeneration = new PeerGenerationGuard();
let capabilities = null;
let viewerKeyPair = null;
let encryptedRoute = null;
let sessionId = null;
let currentNegotiationId = null;
let negotiationUsesControl = false;
let pendingRemoteICE = [];
let sessionEnded = false;
let sentICECandidates = 0;
let receivedICECandidates = 0;
const intentionallyClosedSockets = new WeakSet();
let connecting = false;
let reconnectAttempts = 0;
let reconnectTimer = null;
const maxReconnectAttempts = 12;
let uiTimeout;
let statsInterval;
let statsCollectionGeneration = 0;
const inboundStatsHistory = new Map();
const inboundAudioStatsHistory = new Map();
window.__clipLiveShareAudioDiagnostics = Object.freeze({
  updatedAt: null,
  tracks: Object.freeze([]),
});
let showStats = false;
let currentScale = "fit";
let accessCode = "";
let pendingAuthChallenge = null;
let audioTrack = null;
let sharedSystemAudioEnabled = false;
let audioMuted = true;
let audioPlaybackUnlocked = false;

// Multi-stream state
let streams = {}; // presentation index -> { id, stream, browserTrackId, info }
let streamOrder = []; // active presentation indices in manifest order
let streamsInfo = []; // canonical opaque manifest entries
let streamIndexById = new Map();
let pendingVideoTracks = new Map(); // browser MediaStreamTrack.id -> MediaStream
let nextStreamIndex = 0;
let viewerFocusedIndex = null; // What the viewer has selected (index)
let sharerFocusedIndex = null; // What the sharer has focused (index from OS)
let controlDC = null; // DataChannel for control messages

// Layout state
let currentLayout = "focus"; // 'focus', 'grid', or 'row'
let proportionalSizing = true; // true = auto-size based on resolution, false = equal size
let followMode = true; // true = auto-follow sharer's focused window
let gridCells = {}; // index -> { cell, video, label }
let rowCells = {}; // index -> { cell, video, label } for row mode
let selectedGridIndex = null; // Currently selected stream in grid/row mode

// Pan/zoom state
let panZoomState = {
  scale: 1,
  translateX: 0,
  translateY: 0,
  isPanning: false,
  startX: 0,
  startY: 0,
  lastX: 0,
  lastY: 0,
  // Cached dimensions for performance (avoid getBoundingClientRect in move handler)
  containerWidth: 0,
  containerHeight: 0,
  maxX: 0,
  maxY: 0,
  rafId: null,
};
let canPan = false; // True when content is larger than viewport
let minimapUpdateInterval = null;

// Cursor following state
let cursorFollowState = {
  cursorInView: false,
  // Focus mode
  targetX: 0,
  targetY: 0,
  animating: false,
  animationId: null,
  // Row mode
  rowTargetX: 0,
  rowTargetY: 0,
  rowAnimating: false,
  rowAnimationId: null,
};
const CURSOR_LERP_FACTOR = 0.05; // Smooth factor (0-1, higher = faster)

// Password dialog elements
const passwordDialog = document.getElementById("password-dialog");
const passwordForm = document.getElementById("password-form");
const passwordInput = document.getElementById("password-input");
const passwordError = document.getElementById("password-error");
const passwordRoomCode = document.getElementById("password-room-code");

// Initialize
console.log("Clip Live Share viewer initializing");

// UI visibility
function showUI() {
  document.body.classList.add("show-ui");
  statusBar.classList.add("visible");
  controlBar.classList.add("visible");
  if (showStats) statsPanel.classList.add("visible");
  // Show thumbnails bar if multi-stream in focus mode
  if (streamOrder.length > 1 && currentLayout === "focus") {
    thumbnailsBar.classList.add("visible");
  }

  clearTimeout(uiTimeout);
  uiTimeout = setTimeout(hideUI, 3000);
}

function hideUI() {
  if (!mainVideo.srcObject) return;
  document.body.classList.remove("show-ui");
  statusBar.classList.remove("visible");
  controlBar.classList.remove("visible");
  shortcutsHelp.classList.remove("visible");
  if (!showStats) statsPanel.classList.remove("visible");
  // Hide thumbnails bar with the rest of the UI
  thumbnailsBar.classList.remove("visible");
}

// Event listeners for UI visibility
document.addEventListener("mousemove", showUI);
document.addEventListener("mousedown", showUI);
document.addEventListener("keydown", showUI);

// Status updates
function setStatus(text, state) {
  statusText.textContent = text;
  statusDot.className = "status-dot " + state;

  if (state === "connecting") {
    waitingTitle.textContent = text;
    waitingSubtitle.textContent = "Please wait...";
  } else if (state === "error") {
    waitingTitle.textContent = "Connection Error";
    waitingSubtitle.textContent = text;
  }
}

function setWaitingState(title, subtitle) {
  waitingTitle.textContent = title;
  waitingSubtitle.textContent = subtitle;
}

// Multi-stream functions
let updateUITimeout = null;
let thumbnailElements = {}; // idx -> { container, video, label }
let lastSkipToLive = 0; // Throttle skip-to-live to avoid rapid resets

// Skip to live - reset video element to flush accumulated buffer
// Called after current-interval jitter-buffer delay remains above 250ms.
function skipToLive() {
  const now = Date.now();
  // Throttle to max once every 5 seconds to avoid reset loops
  if (now - lastSkipToLive < 5000) return;
  lastSkipToLive = now;

  console.log("Skipping to live - resetting video streams");

  // Reset main video
  if (mainVideo && mainVideo.srcObject) {
    const src = mainVideo.srcObject;
    mainVideo.srcObject = null;
    mainVideo.srcObject = src;
    mainVideo
      .play()
      .catch((e) => console.log("Skip-to-live play error:", e));
  }

  // Reset grid videos
  Object.values(gridCells).forEach((cell) => {
    if (cell.video && cell.video.srcObject) {
      const src = cell.video.srcObject;
      cell.video.srcObject = null;
      cell.video.srcObject = src;
      cell.video
        .play()
        .catch((e) => console.log("Skip-to-live grid play error:", e));
    }
  });

  // Reset row videos
  Object.values(rowCells).forEach((cell) => {
    if (cell.video && cell.video.srcObject) {
      const src = cell.video.srcObject;
      cell.video.srcObject = null;
      cell.video.srcObject = src;
      cell.video
        .play()
        .catch((e) => console.log("Skip-to-live row play error:", e));
    }
  });
}

function updateMultiStreamUI() {
  // Debounce rapid updates
  if (updateUITimeout) {
    clearTimeout(updateUITimeout);
  }
  updateUITimeout = setTimeout(doUpdateMultiStreamUI, 50);
}

function doUpdateMultiStreamUI() {
  const streamCount = streamOrder.length;

  // Update stream count display
  streamCountText.textContent = streamCount;
  streamCountEl.classList.toggle("visible", streamCount > 1);

  // Update layout selector visibility
  updateLayoutSelectorVisibility();

  // Handle based on current layout
  if (currentLayout === "grid") {
    // In grid mode, update the grid
    updateGridLayout();
    return;
  }

  if (currentLayout === "row") {
    // In row mode, update the row
    updateRowLayout();
    return;
  }

  // Focus mode: Show/hide thumbnails bar (show when more than 1 stream
  // and the overall UI is currently visible)
  const showThumbnails = streamCount > 1;
  const uiVisible = document.body.classList.contains("show-ui");
  thumbnailsBar.classList.toggle("visible", showThumbnails && uiVisible);

  if (!showThumbnails) {
    // Clean up all thumbnails
    thumbnailsBar.innerHTML = "";
    thumbnailElements = {};
    return;
  }

  // Sort streamOrder for consistent display
  const sortedOrder = [...streamOrder].sort((a, b) => a - b);

  // Remove thumbnails for streams that no longer exist
  for (const idx in thumbnailElements) {
    if (!streams[idx] || !sortedOrder.includes(parseInt(idx))) {
      thumbnailElements[idx].container.remove();
      delete thumbnailElements[idx];
    }
  }

  // Update or create thumbnails
  for (const idx of sortedOrder) {
    const data = streams[idx];
    if (!data || !data.stream) continue;

    let elem = thumbnailElements[idx];

    if (!elem) {
      // Create new thumbnail
      const container = document.createElement("div");
      container.className = "thumbnail-container";
      container.dataset.streamIndex = idx;

      const video = document.createElement("video");
      video.className = "thumbnail-video";
      video.autoplay = true;
      video.playsinline = true;
      video.muted = true;

      const label = document.createElement("div");
      label.className = "thumbnail-label";

      const focusIndicator = document.createElement("div");
      focusIndicator.className = "thumbnail-focus-indicator";

      container.appendChild(video);
      container.appendChild(label);
      container.appendChild(focusIndicator);

      container.addEventListener("click", () => switchToStream(idx));

      elem = { container, video, label };
      thumbnailElements[idx] = elem;
    }

    // Update video source if changed
    if (elem.video.srcObject !== data.stream) {
      elem.video.srcObject = data.stream;
      elem.video
        .play()
        .catch((e) =>
          console.log("Thumbnail play error for", idx, ":", e.message),
        );
    }

    // Update label
    const info = data.info;
    elem.label.textContent =
      info?.windowName || info?.appName || `Stream ${idx + 1}`;

    // Update classes
    elem.container.classList.toggle(
      "focused",
      idx === sharerFocusedIndex,
    );
    elem.container.classList.toggle("active", idx === viewerFocusedIndex);

    // Ensure it's in the DOM and in correct order
    if (!elem.container.parentNode) {
      thumbnailsBar.appendChild(elem.container);
    }
  }

  // Reorder thumbnails to match sortedOrder
  for (const idx of sortedOrder) {
    if (thumbnailElements[idx]) {
      thumbnailsBar.appendChild(thumbnailElements[idx].container);
    }
  }
}

function switchToStream(index) {
  if (!streams[index]) {
    console.log("switchToStream: stream", index, "not found");
    return;
  }

  console.log("Switching to stream", index);

  // Cancel any ongoing cursor follow animation
  if (cursorFollowState.animationId) {
    cancelAnimationFrame(cursorFollowState.animationId);
    cursorFollowState.animationId = null;
  }
  cursorFollowState.animating = false;

  // Swap the focused stream
  viewerFocusedIndex = index;
  selectedGridIndex = index;

  // Reset pan/zoom state before switching
  panZoomState.translateX = 0;
  panZoomState.translateY = 0;

  // Clear transform immediately to avoid stale positioning
  panZoomContent.style.transform = "";

  // Update main video (for focus mode)
  mainVideo.srcObject = streams[index].stream;
  mainVideo
    .play()
    .catch((e) => console.log("Main video play error:", e.message));

  // Always wait for fresh dimensions via loadedmetadata
  // Don't trust current videoWidth/videoHeight - they may be stale
  const onMetadataLoaded = () => {
    mainVideo.removeEventListener('loadedmetadata', onMetadataLoaded);
    updatePanZoomState();
  };
  mainVideo.addEventListener('loadedmetadata', onMetadataLoaded);

  // Fallback timeout in case loadedmetadata already fired or doesn't fire
  setTimeout(updatePanZoomState, 150);

  // Update UI based on current layout
  updateMultiStreamUI();
}

function presentationIndex(streamId) {
  if (!streamIndexById.has(streamId)) {
    streamIndexById.set(streamId, nextStreamIndex++);
  }
  return streamIndexById.get(streamId);
}

function streamIndexForID(streamId) {
  return typeof streamId === "string" ? streamIndexById.get(streamId) ?? null : null;
}

function resetStreamState({ keepPendingTracks = false } = {}) {
  streams = {};
  streamOrder = [];
  streamsInfo = [];
  streamIndexById = new Map();
  nextStreamIndex = 0;
  if (!keepPendingTracks) pendingVideoTracks = new Map();
  viewerFocusedIndex = null;
  sharerFocusedIndex = null;
  selectedGridIndex = null;
  mainVideo.srcObject = null;
  streamStats.style.display = "none";
  updateMultiStreamUI();
}

function trackForMediaID(mediaTrackId) {
  const pending = pendingVideoTracks.get(mediaTrackId);
  if (pending) return pending;
  const track = pc?.getReceivers().map((receiver) => receiver.track).find(
    (candidate) => candidate?.kind === "video" && candidate.id === mediaTrackId,
  );
  return track ? new MediaStream([track]) : null;
}

function showFirstAvailableStream() {
  if (streamOrder.length === 0) {
    viewerFocusedIndex = null;
    mainVideo.srcObject = null;
    setStatus("Waiting for stream", "connecting");
    setWaitingState("Nothing is being shared", "Waiting for Clip to share a window…");
    waitingEl.classList.remove("hidden");
    streamStats.style.display = "none";
    return;
  }
  const preferred =
    sharerFocusedIndex !== null && streamOrder.includes(sharerFocusedIndex)
      ? sharerFocusedIndex
      : streamOrder[0];
  if (viewerFocusedIndex === null || !streams[viewerFocusedIndex]) {
    switchToStream(preferred);
  }
  setStatus("Connected", "connected");
  waitingEl.classList.add("hidden");
  streamStats.style.display = "flex";
  startStatsCollection();
  showUI();
}

function handleManifest(rawManifest) {
  const manifest = canonicalManifest(rawManifest);
  const activeIDs = new Set(manifest.filter((entry) => entry.active).map((entry) => entry.id));
  streamsInfo = manifest.map((entry) => ({ ...entry }));

  for (const entry of manifest) {
    const index = presentationIndex(entry.id);
    const mediaStream = trackForMediaID(entry.mediaTrackId);
    if (mediaStream) {
      streams[index] = {
        id: entry.id,
        stream: mediaStream,
        browserTrackId: entry.mediaTrackId,
        info: { ...entry },
      };
    } else if (streams[index]) {
      streams[index].info = { ...entry };
    }
    if (entry.focused) sharerFocusedIndex = index;
  }

  for (const [id, index] of streamIndexById.entries()) {
    if (!activeIDs.has(id)) {
      delete streams[index];
    }
  }
  streamOrder = manifest
    .filter((entry) => entry.active)
    .map((entry) => streamIndexForID(entry.id))
    .filter((index) => index !== null && streams[index]);

  if (manifest.length > 0 && streamOrder.length === 0) {
    setStatus("Receiving stream…", "connecting");
  }
  showFirstAvailableStream();
  if (followMode && sharerFocusedIndex !== null && streams[sharerFocusedIndex]) {
    handleFocusChange(streams[sharerFocusedIndex].id);
  }
  updateMultiStreamUI();
}

function handleFocusChange(streamId) {
  sharerFocusedIndex = streamIndexForID(streamId);
  if (followMode && sharerFocusedIndex !== null && streams[sharerFocusedIndex]) {
    if (currentLayout === "row") {
      rowCells[sharerFocusedIndex]?.cell?.scrollIntoView({
        behavior: "smooth",
        inline: "center",
        block: "nearest",
      });
    } else {
      switchToStream(sharerFocusedIndex);
    }
  }
  updateMultiStreamUI();
}

async function handleControlMessage(message) {
  if (!message || message.version !== CLIP_PROTOCOL_VERSION) {
    throw new ClipProtocolError("invalid-control", "Clip sent an invalid control message.");
  }
  if (!sessionId || message.sessionId !== sessionId) {
    throw new ClipProtocolError("session-mismatch", "Control data belongs to another session.");
  }
  switch (message.type) {
    case "manifest":
      handleManifest(message);
      break;
    case "stream-state":
      if (!isOpaqueIdentifier(message.streamId) || typeof message.active !== "boolean") {
        throw new ClipProtocolError("invalid-stream-state", "Clip sent an invalid stream state.");
      }
      if (message.active) {
        const existing = streamsInfo.find((entry) => entry.id === message.streamId);
        if (!existing) {
          throw new ClipProtocolError("unknown-stream", "Clip activated an unknown stream.");
        }
        handleStreamActivated({ ...existing, active: true });
      } else {
        handleStreamDeactivated(message.streamId);
      }
      break;
    case "focus":
      if (message.streamId === null) {
        sharerFocusedIndex = null;
        updateMultiStreamUI();
      } else {
        if (!isOpaqueIdentifier(message.streamId) || streamIndexForID(message.streamId) === null) {
          throw new ClipProtocolError("unknown-stream", "Clip focused an unknown stream.");
        }
        handleFocusChange(message.streamId);
      }
      break;
    case "geometry":
      if (
        !isOpaqueIdentifier(message.streamId) ||
        streamIndexForID(message.streamId) === null ||
        !Number.isSafeInteger(message.width) ||
        !Number.isSafeInteger(message.height) ||
        message.width < 1 ||
        message.height < 1 ||
        message.width > 32_768 ||
        message.height > 32_768
      ) {
        throw new ClipProtocolError("invalid-geometry", "Clip sent invalid stream geometry.");
      }
      handleSizeChange(message.streamId, message.width, message.height);
      break;
    case "cursor":
      if (
        !isOpaqueIdentifier(message.streamId) ||
        streamIndexForID(message.streamId) === null ||
        !Number.isFinite(message.x) ||
        !Number.isFinite(message.y) ||
        message.x < 0 ||
        message.x > 100 ||
        message.y < 0 ||
        message.y > 100 ||
        typeof message.inView !== "boolean"
      ) {
        throw new ClipProtocolError("invalid-cursor", "Clip sent an invalid cursor position.");
      }
      handleCursorPosition(message.streamId, message.x, message.y, message.inView);
      break;
    case "sharing-state":
      if (typeof message.sharing !== "boolean") {
        throw new ClipProtocolError("invalid-sharing-state", "Clip sent an invalid sharing state.");
      }
      if (message.sharing) {
        setStatus("Connected", "connected");
      } else {
        resetStreamState({ keepPendingTracks: true });
        setWaitingState("Sharing paused", "Waiting for Clip to share a window…");
        waitingEl.classList.remove("hidden");
      }
      break;
    case "system-audio-state":
      sharedSystemAudioEnabled = canonicalSystemAudioState(message);
      if (!sharedSystemAudioEnabled) {
        systemAudio.pause();
        audioUnlock.classList.remove("visible");
      }
      syncAudioControls();
      if (sharedSystemAudioEnabled) await attemptAudioPlayback();
      break;
    case "codec-offer":
      await handleRenegotiationOffer(message.sdp, message.negotiationId);
      break;
    case "codec-ice":
      await handleRemoteICE(message);
      break;
    case "session-closing":
      if (!isOptionalText(message.reason, 512)) {
        throw new ClipProtocolError("invalid-closing", "Clip sent an invalid session closing reason.");
      }
      // Echo the authenticated closing message as a delivery acknowledgement.
      // Clip waits only a bounded interval, but this prevents normal shutdown
      // from closing DTLS before the browser learns that reconnecting is wrong.
      sendControlMessage({
        type: "session-closing",
        version: CLIP_PROTOCOL_VERSION,
        sessionId,
      });
      sessionEnded = true;
      resetStreamState();
      setStatus("Share ended", "error");
      setWaitingState("Live Share ended", message.reason || "The host stopped this session.");
      waitingEl.classList.remove("hidden");
      setTimeout(() => {
        if (sessionEnded) clearPeerConnection();
      }, 600);
      break;
    default:
      throw new ClipProtocolError("unknown-control", "Clip sent an unknown control message.");
  }
}

// Cursor position handling for auto-follow
function handleCursorPosition(trackId, cursorX, cursorY, cursorInView) {
  // Only process if follow mode is enabled
  if (!followMode) return;

  const streamIndex = streamIndexForID(trackId);
  if (streamIndex === null) return;

  cursorFollowState.cursorInView = cursorInView;

  if (!cursorInView) {
    return;
  }

  // Handle ROW layout - scroll the row container
  if (currentLayout === "row") {
    const cell = rowCells[streamIndex];
    if (!cell || !cell.video) return;

    const video = cell.video;
    const videoWidth =
      video.videoWidth || parseInt(video.style.width) || 0;
    const videoHeight =
      video.videoHeight || parseInt(video.style.height) || 0;
    if (!videoWidth || !videoHeight) return;

    // Get row container and cell position
    const rowRect = videoRow.getBoundingClientRect();
    const cellRect = cell.cell.getBoundingClientRect();

    // Check if video is larger than viewport (needs internal panning)
    const needsInternalHorizontalPan = videoWidth > rowRect.width;
    const needsInternalVerticalPan = videoHeight > rowRect.height;

    // Convert cursor percentage to pixel position within the video
    const cursorPixelX = (cursorX / 100) * videoWidth;
    const cursorPixelY = (cursorY / 100) * videoHeight;

    // Calculate cursor position relative to the row's scroll area
    const cursorInRowX =
      cellRect.left - rowRect.left + videoRow.scrollLeft + cursorPixelX;
    const cursorInRowY =
      cellRect.top - rowRect.top + videoRow.scrollTop + cursorPixelY;

    // Calculate cell center position for centering
    const cellCenterX =
      cellRect.left -
      rowRect.left +
      videoRow.scrollLeft +
      cellRect.width / 2;
    const cellCenterY =
      cellRect.top -
      rowRect.top +
      videoRow.scrollTop +
      cellRect.height / 2;

    // Target scroll position:
    // - Horizontal: center cursor if video is wide, otherwise center the cell
    // - Vertical: center cursor if video is tall, otherwise center the cell
    const targetScrollX = needsInternalHorizontalPan
      ? cursorInRowX - rowRect.width / 2
      : cellCenterX - rowRect.width / 2;
    const targetScrollY = needsInternalVerticalPan
      ? cursorInRowY - rowRect.height / 2
      : cellCenterY - rowRect.height / 2;

    // Set target and start smooth animation
    cursorFollowState.rowTargetX = Math.max(0, targetScrollX);
    cursorFollowState.rowTargetY = Math.max(0, targetScrollY);
    if (!cursorFollowState.rowAnimating) {
      cursorFollowState.rowAnimating = true;
      animateRowScroll();
    }
    return;
  }

  // Handle FOCUS layout with native scale - use pan/zoom
  if (currentLayout === "focus" && currentScale === "native" && canPan) {
    if (streamIndex !== viewerFocusedIndex) return;

    // Calculate target pan position to center cursor in viewport
    const containerRect = mainVideoContainer.getBoundingClientRect();
    const videoWidth = mainVideo.videoWidth;
    const videoHeight = mainVideo.videoHeight;

    if (!videoWidth || !videoHeight) return;

    // Convert percentage to pixel position in video
    const cursorPixelX = (cursorX / 100) * videoWidth;
    const cursorPixelY = (cursorY / 100) * videoHeight;

    // Calculate pan needed to center cursor in viewport
    // Target: cursor should be at center of viewport
    const targetX = containerRect.width / 2 - cursorPixelX;
    const targetY = containerRect.height / 2 - cursorPixelY;

    // Clamp to valid pan bounds
    const maxX = Math.max(0, videoWidth - containerRect.width);
    const maxY = Math.max(0, videoHeight - containerRect.height);

    // Set target and start smooth animation
    cursorFollowState.targetX = Math.max(-maxX, Math.min(0, targetX));
    cursorFollowState.targetY = Math.max(-maxY, Math.min(0, targetY));
    if (!cursorFollowState.animating) {
      cursorFollowState.animating = true;
      animateFocusPan();
    }
  }
}

// Lerp animation for focus mode panning
function animateFocusPan() {
  if (!cursorFollowState.animating) return;

  const dx = cursorFollowState.targetX - panZoomState.translateX;
  const dy = cursorFollowState.targetY - panZoomState.translateY;

  // Check if close enough to snap
  if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) {
    panZoomState.translateX = cursorFollowState.targetX;
    panZoomState.translateY = cursorFollowState.targetY;
    applyPanZoomTransform();
    updateMinimap();
    cursorFollowState.animating = false;
    return;
  }

  // Lerp towards target
  panZoomState.translateX += dx * CURSOR_LERP_FACTOR;
  panZoomState.translateY += dy * CURSOR_LERP_FACTOR;
  applyPanZoomTransform();
  updateMinimap();

  cursorFollowState.animationId = requestAnimationFrame(animateFocusPan);
}

// Lerp animation for row mode scrolling
function animateRowScroll() {
  if (!cursorFollowState.rowAnimating) return;

  const currentX = videoRow.scrollLeft;
  const currentY = videoRow.scrollTop;
  const dx = cursorFollowState.rowTargetX - currentX;
  const dy = cursorFollowState.rowTargetY - currentY;

  // Check if close enough to snap
  if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) {
    videoRow.scrollLeft = cursorFollowState.rowTargetX;
    videoRow.scrollTop = cursorFollowState.rowTargetY;
    cursorFollowState.rowAnimating = false;
    return;
  }

  // Lerp towards target
  videoRow.scrollLeft = currentX + dx * CURSOR_LERP_FACTOR;
  videoRow.scrollTop = currentY + dy * CURSOR_LERP_FACTOR;

  cursorFollowState.rowAnimationId =
    requestAnimationFrame(animateRowScroll);
}

function handleSizeChange(trackId, width, height) {
  console.log("Size change received:", trackId, width, height);

  // Update streamsInfo with new dimensions
  const info = streamsInfo.find((i) => i.id === trackId);
  if (info) {
    info.width = width;
    info.height = height;
  }

  // Also update in streams object
  const streamIndex = streamIndexForID(trackId);
  if (streamIndex === null) return;
  if (streams[streamIndex] && streams[streamIndex].info) {
    streams[streamIndex].info.width = width;
    streams[streamIndex].info.height = height;
  }

  // If in grid mode with proportional sizing, recalculate layout
  if (currentLayout === "grid" && proportionalSizing) {
    updateGridLayout();
  }

  // Update pan/zoom state for focus mode
  if (currentLayout === "focus") {
    setTimeout(updatePanZoomState, 100);
  }

  // If this is the currently displayed stream, reset the video element
  // to force the browser to re-detect the new dimensions
  if (viewerFocusedIndex === streamIndex && mainVideo.srcObject) {
    console.log("Resetting video element for dimension change");
    const currentSrc = mainVideo.srcObject;
    mainVideo.srcObject = null;
    requestAnimationFrame(() => {
      mainVideo.srcObject = currentSrc;
      mainVideo
        .play()
        .catch((e) => console.log("Autoplay blocked after resize:", e));
    });
  }
}

// Handle renegotiation offer (when tracks are added/removed dynamically)
async function handleRenegotiationOffer(sdp, negotiationId) {
  const connection = pc;
  if (!connection) {
    console.error("No peer connection for renegotiation");
    return;
  }
  const generation = peerGeneration.generation;
  const isCurrent = () =>
    pc === connection &&
    currentNegotiationId === negotiationId &&
    peerGeneration.isCurrent(connection, generation);
  assertSessionDescription(sdp, negotiationId, "invalid-codec-offer");
  currentNegotiationId = negotiationId;
  negotiationUsesControl = true;
  sentICECandidates = 0;
  receivedICECandidates = 0;

  console.log(
    "Processing renegotiation offer, current signaling state:",
    connection.signalingState,
  );
  console.log(
    "Current streams before renegotiation:",
    Object.keys(streams),
    "streamOrder:",
    streamOrder,
  );

  // DON'T clear streams here - with pre-allocated slots, tracks are reused
  // and ontrack won't fire again. Only clear if we actually get new tracks.
  const previousFocusIndex = viewerFocusedIndex;
  console.log(
    "Processing renegotiation, keeping existing streams:",
    Object.keys(streams),
    "streamOrder:",
    streamOrder,
  );

  // We'll let ontrack update streams if new tracks arrive
  // For pre-allocated slots with same tracks, ontrack won't fire and
  // existing streams will be preserved
  // Don't clear mainVideo.srcObject - keep showing current stream during renegotiation

  // If we're not in stable state, we need to handle this carefully
  // This can happen if we receive an offer while we have a pending local offer
  if (
    connection.signalingState !== "stable" &&
    connection.signalingState !== "have-remote-offer"
  ) {
    console.log("Not in stable state, waiting for state to stabilize...");
    // Wait a bit and try again
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (!isCurrent()) return;
    if (connection.signalingState !== "stable") {
      console.error(
        "Still not in stable state after wait:",
        connection.signalingState,
      );
      // Try to rollback if possible
      try {
        await connection.setLocalDescription({ type: "rollback" });
        if (!isCurrent()) return;
        console.log("Rolled back local description");
      } catch (rollbackErr) {
        if (!isCurrent()) return;
        console.error("Rollback failed:", rollbackErr);
      }
    }
  }

  try {
    console.log("Setting remote description for renegotiation");
    await connection.setRemoteDescription({ type: "offer", sdp });
    if (!isCurrent()) return;
    console.log("Remote description set, creating answer");

    const answer = await connection.createAnswer();
    if (!isCurrent()) return;
    console.log("Answer created, setting local description");
    const normalizedAnswer = {
      type: answer.type,
      sdp: normalizeOpusSystemAudioSDP(answer.sdp),
    };
    await connection.setLocalDescription(normalizedAnswer);
    if (!isCurrent()) return;

    const answerSDP =
      connection.localDescription?.sdp || normalizedAnswer.sdp;
    assertSessionDescription(answerSDP, negotiationId, "invalid-codec-answer");

    sendControlMessage({
      type: "codec-answer",
      version: CLIP_PROTOCOL_VERSION,
      sessionId,
      negotiationId,
      sdp: answerSDP,
    });
    console.log("Renegotiation answer sent successfully");

    // Restore focus to previous index if valid (will be applied when ontrack fires)
    if (previousFocusIndex !== null) {
      console.log(
        "Will restore focus to index",
        previousFocusIndex,
        "when track arrives",
      );
      // viewerFocusedIndex is kept so ontrack knows which stream to display
    }
  } catch (e) {
    if (!isCurrent()) return;
    console.error("Renegotiation failed:", e);
    console.error(
      "PC state:",
      connection.signalingState,
      connection.connectionState,
    );
    try {
      sendControlMessage(
        createInnerProtocolFailure(
          sessionId,
          "renegotiation-failed",
          "The browser could not apply Clip's WebRTC update.",
        ),
      );
    } catch (controlError) {
      console.debug(
        "Could not report renegotiation failure to Clip:",
        controlError,
      );
    }
    // An RTCPeerConnection whose description update failed is no longer a
    // reliable base for the next offer. Reopen a fresh encrypted route while
    // the generation guard prevents this task from closing a replacement peer.
    if (isCurrent()) restartPeer("WebRTC update failed");
  }
}

// Handle stream removed notification
function handleStreamRemoved(trackID) {
  const removedIndex = streamIndexForID(trackID);
  if (removedIndex === null) return;
  delete streams[removedIndex];
  streamOrder = streamOrder.filter((idx) => idx !== removedIndex);
  streamsInfo = streamsInfo.filter((info) => info.id !== trackID);
  if (viewerFocusedIndex === removedIndex) {
    viewerFocusedIndex = null;
    showFirstAvailableStream();
  }
  if (sharerFocusedIndex === removedIndex) {
    sharerFocusedIndex = null;
  }
  updateMultiStreamUI();
}

// Handle stream activated (fast path - no renegotiation needed)
// The track already exists in the peer connection, just start using it
function handleStreamActivated(info) {
  if (!info) return;
  const existing = streamsInfo.filter((entry) => entry.id !== info.id);
  handleManifest({ streams: [...existing, { ...info, active: true }] });
}

// Handle stream deactivated (fast path - no renegotiation needed)
// The track still exists but is no longer active
function handleStreamDeactivated(trackID) {
  const current = streamsInfo.find((entry) => entry.id === trackID);
  if (!current) return;
  handleManifest({
    streams: streamsInfo.map((entry) =>
      entry.id === trackID ? { ...entry, active: false } : entry,
    ),
  });
}

// Fullscreen
function toggleFullscreen() {
  if (!document.fullscreenElement) {
    document.documentElement
      .requestFullscreen()
      .catch((e) => console.log("Fullscreen error:", e));
  } else {
    document.exitFullscreen();
  }
}

document.addEventListener("fullscreenchange", () => {
  const btn = document.getElementById("btn-fullscreen");
  if (document.fullscreenElement) {
    btn.classList.add("active");
    showUI();
  } else {
    btn.classList.remove("active");
  }
  // Update pan/zoom state for new dimensions (cursor following depends on canPan)
  if (currentScale === "native") {
    setTimeout(updatePanZoomState, 100);
  }
});

// Picture-in-Picture
async function togglePiP() {
  try {
    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    } else if (mainVideo.srcObject) {
      await mainVideo.requestPictureInPicture();
    }
  } catch (e) {
    console.log("PiP error:", e);
  }
}

mainVideo.addEventListener("enterpictureinpicture", () => {
  document.getElementById("btn-pip").classList.add("active");
});

mainVideo.addEventListener("leavepictureinpicture", () => {
  document.getElementById("btn-pip").classList.remove("active");
});

// Note: Scale mode, stats toggle, help toggle, keyboard shortcuts,
// and button event listeners are defined in the Layout Management section below

// Password dialog functions
function showPasswordDialog(errorText = "") {
  waitingEl.classList.add("hidden");
  passwordDialog.classList.add("visible");
  passwordInput.value = "";
  passwordInput.classList.toggle("error", !!errorText);
  passwordError.textContent = errorText;
  passwordInput.focus();
}

function hidePasswordDialog() {
  passwordDialog.classList.remove("visible");
  passwordInput.classList.remove("error");
  passwordError.textContent = "";
}

// Password form submission
async function respondToAuthChallenge(challengeMessage) {
  assertInnerMessage(challengeMessage, sessionId);
  let proof;
  if (challengeMessage.accessCodeRequired) {
    proof = await createAuthProof({
      accessCode,
      challenge: challengeMessage.challenge,
      sessionId,
    });
  }
  await sendInner({
    type: "auth-response",
    version: CLIP_PROTOCOL_VERSION,
    sessionId,
    ...(proof ? { proof } : {}),
  });
  setStatus("Authorizing…", "connecting");
  setWaitingState("Authorizing", "Clip is approving this viewer…");
}

passwordForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const value = normalizeAccessCode(passwordInput.value);
  if (!value) {
    passwordInput.classList.add("error");
    passwordError.textContent = "Please enter an access code";
    return;
  }
  accessCode = value;
  hidePasswordDialog();
  waitingEl.classList.remove("hidden");
  try {
    if (pendingAuthChallenge && encryptedRoute) {
      const challenge = pendingAuthChallenge;
      pendingAuthChallenge = null;
      await respondToAuthChallenge(challenge);
    } else {
      restartSignaling("Retrying access code…");
    }
  } catch (error) {
    failViewer(error);
  }
});

// WebRTC Stats collection
function startStatsCollection() {
  if (statsInterval) clearInterval(statsInterval);
  const generation = ++statsCollectionGeneration;
  let pollInFlight = false;
  inboundStatsHistory.clear();
  inboundAudioStatsHistory.clear();
  window.__clipLiveShareAudioDiagnostics = Object.freeze({
    updatedAt: null,
    tracks: Object.freeze([]),
  });

  statsInterval = setInterval(async () => {
    if (!pc || pollInFlight) return;
    const statsPeer = pc;
    pollInFlight = true;

    try {
      const stats = await statsPeer.getStats();
      if (
        generation !== statsCollectionGeneration ||
        statsPeer !== pc
      ) {
        return;
      }
      let videoStats = null;
      let candidatePairStats = null;
      const displayedTrackId =
        mainVideo.srcObject?.getVideoTracks?.()[0]?.id || null;
      const inboundVideoStats = [];
      const inboundAudioStats = [];
      const historyKeyFor = (report) =>
        report.id ||
        report.ssrc ||
        report.trackIdentifier ||
        "unidentified-video";

      stats.forEach((report) => {
        if (report.type === "inbound-rtp" && report.kind === "video") {
          inboundVideoStats.push(report);
        } else if (
          report.type === "inbound-rtp" &&
          report.kind === "audio"
        ) {
          inboundAudioStats.push(report);
        }
      });

      const activeAudioHistoryKeys = new Set();
      const audioDiagnostics = inboundAudioStats.flatMap((report) => {
        const historyKey =
          report.id ||
          report.ssrc ||
          report.trackIdentifier ||
          "unidentified-audio";
        activeAudioHistoryKeys.add(historyKey);
        const diagnostic = inboundAudioDiagnostics(
          report,
          inboundAudioStatsHistory.get(historyKey),
        );
        if (!diagnostic) return [];
        inboundAudioStatsHistory.set(historyKey, diagnostic._baseline);
        const publicValue = publicAudioDiagnostics(diagnostic);
        const codec = report.codecId ? stats.get(report.codecId) : null;
        return [
          {
            ...publicValue,
            codec: typeof codec?.mimeType === "string" ? codec.mimeType : null,
          },
        ];
      });
      for (const historyKey of inboundAudioStatsHistory.keys()) {
        if (!activeAudioHistoryKeys.has(historyKey)) {
          inboundAudioStatsHistory.delete(historyKey);
        }
      }
      window.__clipLiveShareAudioDiagnostics = Object.freeze({
        updatedAt: Date.now(),
        tracks: Object.freeze(audioDiagnostics),
      });

      videoStats = inboundVideoStats.find((report) => {
        if (!displayedTrackId) return false;
        if (report.trackIdentifier === displayedTrackId) return true;
        const receiver = report.receiverId
          ? stats.get(report.receiverId)
          : null;
        return receiver?.trackIdentifier === displayedTrackId;
      });
      if (!videoStats && viewerFocusedIndex !== null) {
        const focusedTrackId = streams[viewerFocusedIndex]?.browserTrackId;
        videoStats = inboundVideoStats.find(
          (report) => report.trackIdentifier === focusedTrackId,
        );
      }
      videoStats ||= inboundVideoStats.find(
        (report) => (report.bytesReceived || 0) > 0,
      );

      const transport = Array.from(stats.values()).find(
        (report) =>
          report.type === "transport" && report.selectedCandidatePairId,
      );
      if (transport) {
        candidatePairStats = stats.get(transport.selectedCandidatePairId);
      }
      candidatePairStats ||= Array.from(stats.values()).find(
        (report) =>
          report.type === "candidate-pair" &&
          report.state === "succeeded" &&
          (report.selected === true || report.nominated === true),
      );

      if (videoStats) {
        const res = `${videoStats.frameWidth || "--"}x${videoStats.frameHeight || "--"}`;
        document.getElementById("stat-resolution").textContent = res;
        document.getElementById("stats-resolution").textContent = res;

        const fps = videoStats.framesPerSecond
          ? Math.round(videoStats.framesPerSecond)
          : "--";
        document.getElementById("stat-fps").textContent = fps;
        document.getElementById("stats-framerate").textContent =
          fps !== "--" ? `${fps} fps` : "--";

        const historyKey = historyKeyFor(videoStats);
        const previous = inboundStatsHistory.get(historyKey);
        const bytesReceived = videoStats.bytesReceived || 0;
        if (
          previous &&
          videoStats.timestamp > previous.timestamp &&
          bytesReceived >= previous.bytesReceived
        ) {
          const timeDiff =
            (videoStats.timestamp - previous.timestamp) / 1000;
          const bytesDiff = bytesReceived - previous.bytesReceived;
          const bitrate = (bytesDiff * 8) / timeDiff / 1000;

          let bitrateStr;
          if (bitrate >= 1000) {
            bitrateStr = (bitrate / 1000).toFixed(1) + " Mbps";
          } else {
            bitrateStr = Math.round(bitrate) + " kbps";
          }
          document.getElementById("stat-bitrate").textContent =
            bitrateStr;
          document.getElementById("stats-bitrate").textContent =
            bitrateStr;
        }
        const packetsLost = videoStats.packetsLost || 0;
        const packetsReceived = videoStats.packetsReceived || 0;
        const lossPercent =
          packetsReceived > 0
            ? (
                (packetsLost / (packetsLost + packetsReceived)) *
                100
              ).toFixed(1)
            : 0;
        const lossEl = document.getElementById("stats-packets-lost");
        lossEl.textContent = `${packetsLost} (${lossPercent}%)`;
        lossEl.className =
          "stats-value " +
          (lossPercent > 5 ? "bad" : lossPercent > 1 ? "warn" : "good");

        const jitter = videoStats.jitter
          ? (videoStats.jitter * 1000).toFixed(1) + " ms"
          : "--";
        document.getElementById("stats-jitter").textContent = jitter;

        let bufferDelayMs = null;
        let decodeTimeMs = null;
        let highBufferSamples = 0;
        if (previous && videoStats.timestamp > previous.timestamp) {
          const emittedDelta =
            (videoStats.jitterBufferEmittedCount || 0) -
            previous.jitterBufferEmittedCount;
          const bufferDelayDelta =
            (videoStats.jitterBufferDelay || 0) -
            previous.jitterBufferDelay;
          if (emittedDelta > 0 && bufferDelayDelta >= 0) {
            bufferDelayMs = (bufferDelayDelta / emittedDelta) * 1000;
          }

          const decodedDelta =
            (videoStats.framesDecoded || 0) - previous.framesDecoded;
          const decodeTimeDelta =
            (videoStats.totalDecodeTime || 0) - previous.totalDecodeTime;
          if (decodedDelta > 0 && decodeTimeDelta >= 0) {
            decodeTimeMs = (decodeTimeDelta / decodedDelta) * 1000;
          }
          highBufferSamples =
            bufferDelayMs !== null && bufferDelayMs > 250
              ? previous.highBufferSamples + 1
              : 0;
        }

        const bufferEl = document.getElementById("stats-video-buffer");
        bufferEl.textContent =
          bufferDelayMs === null ? "--" : `${Math.round(bufferDelayMs)} ms`;
        bufferEl.className =
          "stats-value " +
          (bufferDelayMs > 250
            ? "bad"
            : bufferDelayMs > 80
              ? "warn"
              : "good");

        const decodeEl = document.getElementById("stats-decode-time");
        decodeEl.textContent =
          decodeTimeMs === null ? "--" : `${decodeTimeMs.toFixed(1)} ms`;
        decodeEl.className =
          "stats-value " +
          (decodeTimeMs > 33 ? "bad" : decodeTimeMs > 16 ? "warn" : "good");

        if (highBufferSamples >= 2) {
          console.warn(
            "Current video buffer delay remained high:",
            Math.round(bufferDelayMs),
            "ms - resetting playback to the live edge",
          );
          skipToLive();
          highBufferSamples = 0;
        }

        if (!previous || videoStats.timestamp > previous.timestamp) {
          inboundStatsHistory.set(historyKey, {
            timestamp: videoStats.timestamp,
            bytesReceived,
            jitterBufferDelay: videoStats.jitterBufferDelay || 0,
            jitterBufferEmittedCount:
              videoStats.jitterBufferEmittedCount || 0,
            framesDecoded: videoStats.framesDecoded || 0,
            totalDecodeTime: videoStats.totalDecodeTime || 0,
            highBufferSamples,
          });
        }
      }

      // Keep every inbound track's cumulative baseline current. A track
      // that is not displayed cannot contribute to the consecutive-high
      // streak, so switching back starts with a fresh interval instead
      // of averaging the entire time it was hidden.
      const activeHistoryKeys = new Set();
      inboundVideoStats.forEach((report) => {
        const historyKey = historyKeyFor(report);
        activeHistoryKeys.add(historyKey);
        if (report === videoStats) return;
        const previous = inboundStatsHistory.get(historyKey);
        if (previous && report.timestamp <= previous.timestamp) return;
        inboundStatsHistory.set(historyKey, {
          timestamp: report.timestamp,
          bytesReceived: report.bytesReceived || 0,
          jitterBufferDelay: report.jitterBufferDelay || 0,
          jitterBufferEmittedCount:
            report.jitterBufferEmittedCount || 0,
          framesDecoded: report.framesDecoded || 0,
          totalDecodeTime: report.totalDecodeTime || 0,
          highBufferSamples: 0,
        });
      });
      for (const historyKey of inboundStatsHistory.keys()) {
        if (!activeHistoryKeys.has(historyKey)) {
          inboundStatsHistory.delete(historyKey);
        }
      }

      if (candidatePairStats) {
        const rtt = candidatePairStats.currentRoundTripTime;
        const latencyEl = document.getElementById("stats-latency");
        if (rtt !== undefined) {
          const latencyMs = Math.round(rtt * 1000);
          latencyEl.textContent = latencyMs + " ms";
          latencyEl.className =
            "stats-value " +
            (latencyMs > 200 ? "bad" : latencyMs > 100 ? "warn" : "good");
        } else {
          latencyEl.textContent = "--";
        }

        const connTypeEl = document.getElementById(
          "stats-connection-type",
        );
        const localCandidateId = candidatePairStats.localCandidateId;
        let connectionType = "Unknown";

        stats.forEach((report) => {
          if (
            report.type === "local-candidate" &&
            report.id === localCandidateId
          ) {
            switch (report.candidateType) {
              case "relay":
                connectionType = "Relay (TURN)";
                connTypeEl.className = "stats-value warn";
                break;
              case "host":
                connectionType = "Direct (P2P)";
                connTypeEl.className = "stats-value good";
                break;
              case "srflx":
              case "prflx":
                connectionType = "NAT (P2P)";
                connTypeEl.className = "stats-value good";
                break;
            }
          }
        });
        connTypeEl.textContent = connectionType;
      }
    } catch (e) {
      console.log("Stats error:", e);
    } finally {
      pollInFlight = false;
    }
  }, 1000);
}

function stopStatsCollection() {
  statsCollectionGeneration++;
  inboundStatsHistory.clear();
  inboundAudioStatsHistory.clear();
  window.__clipLiveShareAudioDiagnostics = Object.freeze({
    updatedAt: null,
    tracks: Object.freeze([]),
  });
  if (statsInterval) {
    clearInterval(statsInterval);
    statsInterval = null;
  }
}

// Clip v1 encrypted signaling and WebRTC connection
let websocketMessageChain = Promise.resolve();
let outboundRelayChain = Promise.resolve();

function safeMessage(error) {
  if (error instanceof ClipProtocolError) return error.message;
  return error instanceof Error ? error.message : String(error);
}

function assertSessionDescription(sdp, negotiationId, code = "invalid-description") {
  if (
    !isOpaqueIdentifier(negotiationId) ||
    !isRequiredText(sdp, MAX_SESSION_DESCRIPTION_BYTES)
  ) {
    throw new ClipProtocolError(code, "Clip sent an invalid WebRTC session description.");
  }
}

function assertICECandidate(message) {
  if (
    !isOpaqueIdentifier(message?.negotiationId) ||
    typeof message?.candidate !== "string" ||
    utf8Length(message.candidate) > MAX_ICE_CANDIDATE_BYTES ||
    !isOptionalText(message.sdpMid, 256) ||
    !Number.isSafeInteger(message.sdpMLineIndex) ||
    message.sdpMLineIndex < 0 ||
    message.sdpMLineIndex > 1_024
  ) {
    throw new ClipProtocolError("invalid-candidate", "Clip sent an invalid ICE candidate.");
  }
}

function failViewer(error) {
  console.error("Clip viewer error:", error);
  const message = safeMessage(error);
  setStatus(message, "error");
  setWaitingState("Connection Error", message);
  waitingEl.classList.remove("hidden");
}

async function loadCapabilities() {
  if (capabilities) return capabilities;
  const response = await fetch("/.well-known/clip-live-share", {
    credentials: "same-origin",
    cache: "no-store",
    headers: { Accept: "application/json" },
  });
  if (!response.ok) {
    throw new ClipProtocolError(
      "capabilities-unavailable",
      "The Live Share server is unavailable.",
    );
  }
  capabilities = validateCapabilities(await response.json());
  return capabilities;
}

function sendOuter(message) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    throw new ClipProtocolError("signaling-closed", "The signaling route is closed.");
  }
  const encoded = JSON.stringify(message);
  if (new TextEncoder().encode(encoded).length > capabilities.maximumMessageBytes) {
    throw new ClipProtocolError("message-too-large", "The signaling message is too large.");
  }
  ws.send(encoded);
}

function sendInner(message) {
  const task = outboundRelayChain.then(async () => {
    if (!encryptedRoute) {
      throw new ClipProtocolError("route-not-ready", "The encrypted route is not ready.");
    }
    sendOuter(await encryptedRoute.seal(message));
  });
  outboundRelayChain = task.catch(() => {});
  return task;
}

function sendControlMessage(message) {
  if (!controlDC || controlDC.readyState !== "open") {
    throw new ClipProtocolError("control-closed", "The peer control channel is closed.");
  }
  const encoded = JSON.stringify(message);
  if (new TextEncoder().encode(encoded).length > MAX_INNER_MESSAGE_BYTES) {
    throw new ClipProtocolError("message-too-large", "The control message is too large.");
  }
  controlDC.send(encoded);
}

function closeSignalingRoute() {
  if (!ws) return;
  intentionallyClosedSockets.add(ws);
  try {
    if (ws.readyState === WebSocket.OPEN && encryptedRoute) {
      sendOuter({ type: "close-route", routeId: encryptedRoute.routeId });
    }
  } catch (error) {
    console.debug("Could not close signaling route cleanly:", error);
  }
  try {
    ws.close(1000, "WebRTC control channel active");
  } catch {}
  ws = null;
  encryptedRoute = null;
}

function clearPeerConnection() {
  stopStatsCollection();
  peerGeneration.clear();
  controlDC = null;
  if (pc) {
    pc.ontrack = null;
    pc.ondatachannel = null;
    pc.onicecandidate = null;
    pc.onconnectionstatechange = null;
    pc.oniceconnectionstatechange = null;
    try {
      pc.close();
    } catch {}
    pc = null;
  }
  audioTrack = null;
  sharedSystemAudioEnabled = false;
  systemAudio.pause();
  systemAudio.srcObject = null;
  syncAudioControls();
  resetStreamState();
}

function scheduleReconnect(reason) {
  if (reconnectTimer) return;
  reconnectAttempts += 1;
  const exponent = Math.min(reconnectAttempts - 1, 4);
  const delay = Math.min(1_000 * 2 ** exponent, 10_000);
  const suffix =
    reconnectAttempts > maxReconnectAttempts
      ? "Still trying — the host may be offline"
      : "Attempt " + reconnectAttempts;
  setStatus("Reconnecting in " + Math.round(delay / 1_000) + "s…", "connecting");
  setWaitingState(reason || "Reconnecting…", suffix);
  waitingEl.classList.remove("hidden");
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect().catch(failViewer);
  }, delay);
}

function restartSignaling(reason = "Reconnecting…") {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (ws) {
    intentionallyClosedSockets.add(ws);
    try {
      ws.close(1000, "Opening a fresh route");
    } catch {}
    ws = null;
  }
  encryptedRoute = null;
  viewerKeyPair = null;
  outboundRelayChain = Promise.resolve();
  scheduleReconnect(reason);
}

function restartPeer(reason = "Connection lost") {
  clearPeerConnection();
  restartSignaling(reason);
}

async function connect() {
  if (connecting) return;
  connecting = true;
  encryptedRoute = null;
  sessionId = null;
  sessionEnded = false;
  currentNegotiationId = null;
  pendingRemoteICE = [];
  pendingAuthChallenge = null;
  sentICECandidates = 0;
  receivedICECandidates = 0;
  outboundRelayChain = Promise.resolve();
  try {
    const config = await loadCapabilities();
    viewerKeyPair = await createViewerKeyPair();
    const path = fillPathTemplate(config.viewerWebSocketPathTemplate, roomCode);
    const socket = new WebSocket(websocketURL(path));
    ws = socket;
    websocketMessageChain = Promise.resolve();

    setStatus("Connecting…", "connecting");
    setWaitingState("Connecting…", "Opening an encrypted route to Clip");

    socket.onopen = () => {
      if (ws !== socket) return;
      reconnectAttempts = 0;
      sendOuter({
        type: "viewer-hello",
        version: CLIP_PROTOCOL_VERSION,
        viewerKey: encodeBase64URL(viewerKeyPair.publicKey),
      });
      setStatus("Securing connection…", "connecting");
      setWaitingState("Securing connection", "Performing private key agreement");
    };

    socket.onmessage = (event) => {
      websocketMessageChain = websocketMessageChain
        .then(() => handleOuterMessage(event, socket))
        .catch((error) => {
          failViewer(error);
          try {
            socket.close(1002, "Protocol error");
          } catch {}
        });
    };

    socket.onerror = () => {
      if (ws === socket) setStatus("Connection error", "error");
    };

    socket.onclose = () => {
      if (ws !== socket) return;
      ws = null;
      const shouldReconnect =
        !intentionallyClosedSockets.has(socket) &&
        (!controlDC || controlDC.readyState !== "open");
      encryptedRoute = null;
      if (shouldReconnect) scheduleReconnect("Signaling connection lost");
    };
  } finally {
    connecting = false;
  }
}

async function handleOuterMessage(event, socket) {
  if (ws !== socket) return;
  if (typeof event.data !== "string") {
    throw new ClipProtocolError("invalid-message", "The server sent non-text signaling.");
  }
  if (new TextEncoder().encode(event.data).length > capabilities.maximumMessageBytes) {
    throw new ClipProtocolError("message-too-large", "The server sent an oversized message.");
  }
  let message;
  try {
    message = JSON.parse(event.data);
  } catch {
    throw new ClipProtocolError("invalid-message", "The server sent invalid signaling JSON.");
  }

  switch (message.type) {
    case "route-opened": {
      try {
        decodeBase64URL(message.routeId, 16);
      } catch {
        throw new ClipProtocolError("invalid-route", "The server returned an invalid route.");
      }
      const keys = await deriveRouteKeys({
        privateKey: viewerKeyPair.privateKey,
        roomPublicKey: viewerFragment.roomPublicKey,
        room: roomCode,
        routeId: message.routeId,
      });
      encryptedRoute = new EncryptedRoute({
        room: roomCode,
        routeId: message.routeId,
        ...keys,
      });
      setStatus("Authorizing…", "connecting");
      setWaitingState("Connected to Clip", "Waiting for host approval");
      break;
    }

    case "relay": {
      if (!encryptedRoute) {
        throw new ClipProtocolError("route-not-ready", "Encrypted data arrived before key agreement.");
      }
      const inner = assertInnerMessage(await encryptedRoute.open(message), sessionId);
      await handleInnerMessage(inner);
      break;
    }

    case "route-closed":
      try {
        decodeBase64URL(message.routeId, 16);
      } catch {
        throw new ClipProtocolError("invalid-route", "The server closed an invalid route.");
      }
      if (!isOptionalText(message.reason, 512)) {
        throw new ClipProtocolError("invalid-route", "The server sent an invalid route closure.");
      }
      if (!controlDC || controlDC.readyState !== "open") {
        restartSignaling("Clip closed the signaling route");
      }
      break;

    case "host-unavailable":
      setStatus("Waiting for Clip…", "connecting");
      setWaitingState("Clip is offline", "The viewer will reconnect automatically");
      waitingEl.classList.remove("hidden");
      break;

    case "error": {
      const failure = canonicalProtocolFailure(message);
      throw new ClipProtocolError(failure.code, failure.message);
    }

    default:
      throw new ClipProtocolError("unknown-message", "The server sent an unknown signaling message.");
  }
}

async function handleInnerMessage(message) {
  switch (message.type) {
    case "auth-challenge":
      decodeBase64URL(message.challenge, 32);
      if (typeof message.accessCodeRequired !== "boolean") {
        throw new ClipProtocolError("invalid-challenge", "Clip sent an invalid authorization challenge.");
      }
      sessionId = message.sessionId;
      pendingAuthChallenge = message;
      if (message.accessCodeRequired && !accessCode) {
        showPasswordDialog();
      } else {
        pendingAuthChallenge = null;
        await respondToAuthChallenge(message);
      }
      break;

    case "auth-result":
      if (
        typeof message.allowed !== "boolean" ||
        !isOptionalText(message.reason, 512)
      ) {
        throw new ClipProtocolError("invalid-auth-result", "Clip sent an invalid authorization result.");
      }
      if (!message.allowed) {
        pendingAuthChallenge = null;
        showPasswordDialog(message.reason || "The access code was not accepted.");
        return;
      }
      hidePasswordDialog();
      setStatus("Preparing stream…", "connecting");
      setWaitingState("Authorized", "Waiting for Clip to start WebRTC");
      break;

    case "offer":
      assertSessionDescription(message.sdp, message.negotiationId, "invalid-offer");
      await handleInitialOffer(message.sdp, message.negotiationId);
      break;

    case "ice":
      await handleRemoteICE(message);
      break;

    case "error": {
      const failure = canonicalProtocolFailure(message);
      throw new ClipProtocolError(failure.code, failure.message);
    }

    default:
      throw new ClipProtocolError("unknown-inner-message", "Clip sent an unknown encrypted message.");
  }
}

function attachSystemAudioTrack(track) {
  audioTrack = track;
  track.onended = () => {
    if (audioTrack !== track) return;
    audioTrack = null;
    systemAudio.pause();
    systemAudio.srcObject = null;
    syncAudioControls();
  };
  systemAudio.srcObject = new MediaStream([track]);
  syncAudioControls();
  if (sharedSystemAudioEnabled) attemptAudioPlayback();
}

async function attemptAudioPlayback({ userGesture = false } = {}) {
  if (!audioTrack || !sharedSystemAudioEnabled) return;
  systemAudio.muted = audioMuted;
  systemAudio.volume = Math.max(0, Math.min(1, Number(audioVolume.value) / 100));
  try {
    await systemAudio.play();
    if (userGesture || !audioMuted) audioPlaybackUnlocked = true;
    audioUnlock.classList.remove("visible");
  } catch (error) {
    if (!audioMuted) {
      audioPlaybackUnlocked = false;
      audioUnlock.classList.add("visible");
    }
    console.debug("Browser requires a gesture before system audio playback:", error);
  }
}

function syncAudioControls() {
  const available = Boolean(audioTrack) && sharedSystemAudioEnabled;
  audioButton.disabled = !available;
  audioVolume.disabled = !available;
  audioButton.classList.toggle("muted", audioMuted || !available);
  audioButton.classList.toggle("active", available && !audioMuted);
  audioButton.title = available
    ? audioMuted
      ? "Unmute shared system audio (M)"
      : "Mute shared system audio (M)"
    : "Clip is not sharing system audio";
  if (!available) audioUnlock.classList.remove("visible");
}

async function toggleAudio() {
  if (!audioTrack || !sharedSystemAudioEnabled) return;
  audioMuted = !audioMuted;
  localStorage.setItem("clip-live-share-audio-muted", audioMuted ? "1" : "0");
  syncAudioControls();
  await attemptAudioPlayback({ userGesture: true });
}

function registerVideoTrack(track) {
  const stream = new MediaStream([track]);
  pendingVideoTracks.set(track.id, stream);
  track.onunmute = () => {
    if (streamsInfo.length > 0) handleManifest({ streams: streamsInfo });
  };
  track.onended = () => {
    pendingVideoTracks.delete(track.id);
    const matched = streamsInfo.find((entry) => entry.mediaTrackId === track.id);
    if (matched) handleStreamRemoved(matched.id);
  };
  if (streamsInfo.length > 0) handleManifest({ streams: streamsInfo });
}

function setupControlChannel(channel) {
  if (channel.label !== "clip-control-v1") {
    console.warn("Ignoring unknown DataChannel:", channel.label);
    return;
  }
  controlDC = channel;
  channel.binaryType = "arraybuffer";
  channel.onopen = () => {
    setStatus("Connected", "connected");
    if (streamOrder.length === 0) {
      setWaitingState("Connected", "Waiting for Clip to share a window…");
      waitingEl.classList.remove("hidden");
    } else {
      waitingEl.classList.add("hidden");
    }
    closeSignalingRoute();
  };
  channel.onclose = () => {
    if (controlDC === channel) {
      controlDC = null;
      if (!sessionEnded) restartPeer("Control connection lost");
    }
  };
  channel.onerror = (error) => console.error("Control DataChannel error:", error);
  channel.onmessage = async (event) => {
    try {
      let encoded;
      if (typeof event.data === "string") {
        encoded = event.data;
      } else if (event.data instanceof ArrayBuffer) {
        encoded = new TextDecoder("utf-8", { fatal: true }).decode(event.data);
      } else if (event.data instanceof Blob) {
        encoded = new TextDecoder("utf-8", { fatal: true }).decode(await event.data.arrayBuffer());
      } else {
        throw new ClipProtocolError("invalid-control", "Clip sent unsupported control data.");
      }
      if (new TextEncoder().encode(encoded).length > MAX_INNER_MESSAGE_BYTES) {
        throw new ClipProtocolError("message-too-large", "Clip sent oversized control data.");
      }
      await handleControlMessage(JSON.parse(encoded));
    } catch (error) {
      failViewer(error);
    }
  };
}

async function handleInitialOffer(sdp, negotiationId) {
  clearPeerConnection();
  currentNegotiationId = negotiationId;
  negotiationUsesControl = false;
  const connection = new RTCPeerConnection({
    iceServers: capabilities.iceServers,
  });
  pc = connection;
  const generation = peerGeneration.replace(connection);
  const isCurrent = () =>
    pc === connection && peerGeneration.isCurrent(connection, generation);

  connection.ondatachannel = (event) => {
    if (isCurrent()) setupControlChannel(event.channel);
  };
  connection.ontrack = (event) => {
    if (!isCurrent()) return;
    configureReceiverLatency(event.receiver, event.track.kind);
    if (event.track.kind === "audio") {
      attachSystemAudioTrack(event.track);
    } else if (event.track.kind === "video") {
      registerVideoTrack(event.track);
    }
  };

  connection.onicecandidate = (event) => {
    if (!isCurrent()) return;
    if (!event.candidate) return;
    if (++sentICECandidates > 256) {
      failViewer(new ClipProtocolError("too-many-candidates", "Clip produced too many ICE candidates."));
      return;
    }
    const candidate = event.candidate.toJSON
      ? event.candidate.toJSON()
      : {
          candidate: event.candidate.candidate,
          sdpMid: event.candidate.sdpMid,
          sdpMLineIndex: event.candidate.sdpMLineIndex,
        };
    const message = {
      type: negotiationUsesControl ? "codec-ice" : "ice",
      version: CLIP_PROTOCOL_VERSION,
      sessionId,
      negotiationId: currentNegotiationId,
      candidate: candidate.candidate,
      ...(candidate.sdpMid == null ? {} : { sdpMid: candidate.sdpMid }),
      sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
    };
    try {
      assertICECandidate(message);
      if (negotiationUsesControl) {
        sendControlMessage(message);
      } else {
        sendInner(message).catch(failViewer);
      }
    } catch (error) {
      failViewer(error);
    }
  };

  connection.onconnectionstatechange = () => {
    if (!isCurrent()) return;
    switch (connection.connectionState) {
      case "connected":
        setStatus("Connected", "connected");
        break;
      case "connecting":
        setStatus("Connecting WebRTC…", "connecting");
        break;
      case "disconnected":
        setStatus("Connection interrupted…", "connecting");
        break;
      case "failed":
        restartPeer("WebRTC connection failed");
        break;
      case "closed":
        if (controlDC) restartPeer("WebRTC connection closed");
        break;
    }
  };

  connection.oniceconnectionstatechange = () => {
    if (isCurrent() && connection.iceConnectionState === "failed") {
      restartPeer("Network path changed");
    }
  };

  setStatus("Establishing WebRTC…", "connecting");
  await connection.setRemoteDescription({ type: "offer", sdp });
  if (!isCurrent()) return;
  for (const candidate of pendingRemoteICE.splice(0)) {
    await connection.addIceCandidate(candidate);
    if (!isCurrent()) return;
  }
  const answer = await connection.createAnswer();
  if (!isCurrent()) return;
  const normalizedAnswer = {
    type: answer.type,
    sdp: normalizeOpusSystemAudioSDP(answer.sdp),
  };
  await connection.setLocalDescription(normalizedAnswer);
  if (!isCurrent()) return;
  const answerSDP = connection.localDescription?.sdp || normalizedAnswer.sdp;
  assertSessionDescription(answerSDP, negotiationId, "invalid-answer");
  await sendInner({
    type: "answer",
    version: CLIP_PROTOCOL_VERSION,
    sessionId,
    negotiationId,
    sdp: answerSDP,
  });
}

async function handleRemoteICE(message) {
  assertICECandidate(message);
  if (currentNegotiationId && message.negotiationId !== currentNegotiationId) {
    throw new ClipProtocolError("negotiation-mismatch", "ICE belongs to another negotiation.");
  }
  if (++receivedICECandidates > 256) {
    throw new ClipProtocolError("too-many-candidates", "Clip sent too many ICE candidates.");
  }
  const candidate = {
    candidate: message.candidate,
    sdpMid: message.sdpMid ?? null,
    sdpMLineIndex: message.sdpMLineIndex,
  };
  if (!pc || !pc.remoteDescription) {
    pendingRemoteICE.push(candidate);
  } else {
    await pc.addIceCandidate(candidate);
  }
}

// ==========================================
// Layout Management
// ==========================================

function setLayout(layout) {
  if (layout === currentLayout) return;

  currentLayout = layout;
  console.log("Switching to layout:", layout);

  // Update button states
  document.querySelectorAll(".layout-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.layout === layout);
  });

  // Show/hide proportional toggle (only in grid mode)
  proportionalToggle.classList.toggle(
    "visible",
    layout === "grid" && streamOrder.length > 1,
  );
  layoutDivider.style.display =
    layout === "grid" && streamOrder.length > 1 ? "" : "none";

  // Hide all layout containers first
  mainVideoContainer.style.display = "none";
  videoGrid.classList.remove("visible");
  videoRow.classList.remove("visible");
  rowMinimap.classList.remove("visible");
  thumbnailsBar.classList.remove("visible");

  if (layout === "focus") {
    // Switch to focus mode
    mainVideoContainer.style.display = "";
    const uiVisible = document.body.classList.contains("show-ui");
    thumbnailsBar.classList.toggle("visible", streamOrder.length > 1 && uiVisible);

    // Ensure main video has the focused stream
    if (viewerFocusedIndex !== null && streams[viewerFocusedIndex]) {
      mainVideo.srcObject = streams[viewerFocusedIndex].stream;
      mainVideo.play().catch((e) => console.log("Play error:", e));
    }

    // Clean up grid and row cells
    videoGrid.innerHTML = "";
    gridCells = {};
    cleanupRowCells();
  } else if (layout === "grid") {
    // Switch to grid mode
    videoGrid.classList.add("visible");

    // Clean up row cells
    cleanupRowCells();

    // Build the grid
    updateGridLayout();
  } else if (layout === "row") {
    // Switch to row mode
    videoRow.classList.add("visible");

    // Clean up grid cells
    videoGrid.innerHTML = "";
    gridCells = {};

    // Build the row
    updateRowLayout();
  }
}

function toggleLayout() {
  // Cycle through: focus -> grid -> row -> focus
  const layouts = ["focus", "grid", "row"];
  const currentIdx = layouts.indexOf(currentLayout);
  const nextIdx = (currentIdx + 1) % layouts.length;
  setLayout(layouts[nextIdx]);
}

function cleanupRowCells() {
  videoRow.innerHTML = "";
  rowMinimap.innerHTML = "";
  rowMinimap.classList.remove("visible");
  rowCells = {};
}

function toggleProportionalSizing() {
  proportionalSizing = !proportionalSizing;
  proportionalSwitch.classList.toggle("active", proportionalSizing);

  if (currentLayout === "grid") {
    updateGridLayout();
  }
}

function toggleFollowMode() {
  followMode = !followMode;
  followSwitch.classList.toggle("active", followMode);
  console.log("Follow mode:", followMode ? "ON" : "OFF");

  // Stop animations when follow mode is disabled
  if (!followMode) {
    cursorFollowState.animating = false;
    cursorFollowState.rowAnimating = false;
    if (cursorFollowState.animationId) {
      cancelAnimationFrame(cursorFollowState.animationId);
      cursorFollowState.animationId = null;
    }
    if (cursorFollowState.rowAnimationId) {
      cancelAnimationFrame(cursorFollowState.rowAnimationId);
      cursorFollowState.rowAnimationId = null;
    }
  }
}

function calculateProportionalSizes() {
  const activeStreams = streamOrder.map((idx) => {
    const s = streams[idx];
    const info = s?.info;
    return {
      index: idx,
      width: info?.width || 1920,
      height: info?.height || 1080,
      area: (info?.width || 1920) * (info?.height || 1080),
    };
  });

  if (activeStreams.length === 0) return { cols: [], rows: [] };

  const totalArea = activeStreams.reduce((sum, s) => sum + s.area, 0);

  // Calculate relative weights with minimum of 25%
  const weights = activeStreams.map((s) =>
    Math.max(0.25, s.area / totalArea),
  );
  const weightSum = weights.reduce((a, b) => a + b, 0);
  const normalizedWeights = weights.map((w) => w / weightSum);

  return {
    streams: activeStreams,
    weights: normalizedWeights,
  };
}

function updateGridLayout() {
  const count = streamOrder.length;

  if (count === 0) {
    videoGrid.innerHTML = "";
    videoGrid.className = "visible";
    gridCells = {};
    return;
  }

  // Remove old grid classes
  videoGrid.className = "visible";
  videoGrid.classList.add(`grid-${Math.min(count, 4)}`);
  videoGrid.classList.toggle("equal-size", !proportionalSizing);

  // Calculate proportional sizes
  if (proportionalSizing && count >= 2) {
    const sizes = calculateProportionalSizes();

    if (count === 2) {
      // Side by side: proportional columns
      const w1 = sizes.weights[0] || 0.5;
      const w2 = sizes.weights[1] || 0.5;
      videoGrid.style.setProperty("--col-1", `${w1}fr`);
      videoGrid.style.setProperty("--col-2", `${w2}fr`);
    } else if (count === 3) {
      // 1 large on left, 2 stacked on right
      const w1 = Math.max(sizes.weights[0], 0.4);
      const remaining = 1 - w1;
      videoGrid.style.setProperty("--col-1", `${w1}fr`);
      videoGrid.style.setProperty("--col-2", `${remaining}fr`);

      // Row heights for right side
      const h1 = sizes.weights[1] / (sizes.weights[1] + sizes.weights[2]);
      videoGrid.style.setProperty("--row-1", `${h1}fr`);
      videoGrid.style.setProperty("--row-2", `${1 - h1}fr`);
    } else if (count === 4) {
      // 2x2 grid with proportional sizing
      const topWeight = (sizes.weights[0] + sizes.weights[1]) / 2;
      const bottomWeight = (sizes.weights[2] + sizes.weights[3]) / 2;
      const leftWeight = (sizes.weights[0] + sizes.weights[2]) / 2;
      const rightWeight = (sizes.weights[1] + sizes.weights[3]) / 2;

      videoGrid.style.setProperty(
        "--col-1",
        `${leftWeight / (leftWeight + rightWeight)}fr`,
      );
      videoGrid.style.setProperty(
        "--col-2",
        `${rightWeight / (leftWeight + rightWeight)}fr`,
      );
      videoGrid.style.setProperty(
        "--row-1",
        `${topWeight / (topWeight + bottomWeight)}fr`,
      );
      videoGrid.style.setProperty(
        "--row-2",
        `${bottomWeight / (topWeight + bottomWeight)}fr`,
      );
    }
  } else {
    // Reset to equal sizing
    videoGrid.style.removeProperty("--col-1");
    videoGrid.style.removeProperty("--col-2");
    videoGrid.style.removeProperty("--row-1");
    videoGrid.style.removeProperty("--row-2");
  }

  // Create or update grid cells
  const sortedOrder = [...streamOrder].sort((a, b) => a - b);

  // Remove cells for streams that no longer exist
  for (const idx in gridCells) {
    if (!sortedOrder.includes(parseInt(idx))) {
      gridCells[idx].cell.remove();
      delete gridCells[idx];
    }
  }

  // Create or update cells
  for (const idx of sortedOrder) {
    const data = streams[idx];
    if (!data || !data.stream) continue;

    let cell = gridCells[idx];

    if (!cell) {
      // Create new cell
      const cellEl = document.createElement("div");
      cellEl.className = "grid-cell";
      cellEl.dataset.streamIndex = idx;

      const video = document.createElement("video");
      video.autoplay = true;
      video.playsinline = true;
      video.muted = true;

      const label = document.createElement("div");
      label.className = "grid-cell-label";

      cellEl.appendChild(video);
      cellEl.appendChild(label);

      // Click handlers
      let clickTimeout = null;
      cellEl.addEventListener("click", (e) => {
        if (clickTimeout) {
          // Double click - switch to focus mode with this stream
          clearTimeout(clickTimeout);
          clickTimeout = null;
          viewerFocusedIndex = idx;
          setLayout("focus");
        } else {
          // Single click - just select
          clickTimeout = setTimeout(() => {
            clickTimeout = null;
            selectGridCell(idx);
          }, 250);
        }
      });

      cell = { cell: cellEl, video, label };
      gridCells[idx] = cell;
    }

    // Update video source
    if (cell.video.srcObject !== data.stream) {
      cell.video.srcObject = data.stream;
      cell.video
        .play()
        .catch((e) => console.log("Grid video play error:", e));
    }

    // Update label
    const info = data.info;
    cell.label.textContent =
      info?.windowName || info?.appName || `Stream ${idx + 1}`;

    // Update classes
    cell.cell.classList.toggle("selected", idx === selectedGridIndex);
    cell.cell.classList.toggle(
      "sharer-focused",
      idx === sharerFocusedIndex,
    );

    // Ensure it's in the DOM
    if (!cell.cell.parentNode) {
      videoGrid.appendChild(cell.cell);
    }
  }

  // Reorder cells
  for (const idx of sortedOrder) {
    if (gridCells[idx]) {
      videoGrid.appendChild(gridCells[idx].cell);
    }
  }
}

function selectGridCell(index) {
  selectedGridIndex = index;

  // Update cell classes in grid
  for (const idx in gridCells) {
    gridCells[idx].cell.classList.toggle(
      "selected",
      parseInt(idx) === index,
    );
  }

  // Update cell classes in row
  for (const idx in rowCells) {
    rowCells[idx].cell.classList.toggle(
      "selected",
      parseInt(idx) === index,
    );
  }
}

// Update layout selector visibility based on stream count
function updateLayoutSelectorVisibility() {
  const showSelector = streamOrder.length > 1;
  layoutSelector.classList.toggle("visible", showSelector);
  layoutDivider.style.display =
    showSelector && currentLayout === "grid" ? "" : "none";
  proportionalToggle.classList.toggle(
    "visible",
    showSelector && currentLayout === "grid",
  );

  // Show follow toggle when there are multiple streams OR when cursor following is possible
  // (native scale + can pan in focus mode, or in row mode)
  const showFollow =
    showSelector ||
    (currentScale === "native" && canPan) ||
    currentLayout === "row";
  followToggle.classList.toggle("visible", showFollow);

  // If we only have 1 stream, force focus layout
  if (
    streamOrder.length <= 1 &&
    (currentLayout === "grid" || currentLayout === "row")
  ) {
    setLayout("focus");
  }
}

// ==========================================
// Row Layout
// ==========================================

function updateRowLayout() {
  const count = streamOrder.length;

  if (count === 0) {
    cleanupRowCells();
    return;
  }

  const sortedOrder = [...streamOrder].sort((a, b) => a - b);

  // Remove cells for streams that no longer exist
  for (const idx in rowCells) {
    if (!sortedOrder.includes(parseInt(idx))) {
      rowCells[idx].cell.remove();
      if (rowCells[idx].minimapItem) {
        rowCells[idx].minimapItem.remove();
      }
      delete rowCells[idx];
    }
  }

  // Create or update cells
  for (const idx of sortedOrder) {
    const data = streams[idx];
    if (!data || !data.stream) continue;

    let cell = rowCells[idx];

    if (!cell) {
      // Create new row cell
      const cellEl = document.createElement("div");
      cellEl.className = "row-cell";
      cellEl.dataset.streamIndex = idx;

      const video = document.createElement("video");
      video.autoplay = true;
      video.playsinline = true;
      video.muted = true;

      const label = document.createElement("div");
      label.className = "row-cell-label";

      cellEl.appendChild(video);
      cellEl.appendChild(label);

      // Double click to focus
      cellEl.addEventListener("dblclick", (e) => {
        e.preventDefault();
        viewerFocusedIndex = idx;
        setLayout("focus");
      });

      // Create minimap item
      const minimapItem = document.createElement("div");
      minimapItem.className = "row-minimap-item";
      minimapItem.dataset.streamIndex = idx;
      const minimapCanvas = document.createElement("canvas");
      minimapItem.appendChild(minimapCanvas);

      // Click on minimap item to scroll to that stream
      minimapItem.addEventListener("click", () => {
        const cellElement = rowCells[idx]?.cell;
        if (cellElement) {
          cellElement.scrollIntoView({
            behavior: "smooth",
            inline: "center",
            block: "nearest",
          });
        }
      });

      cell = { cell: cellEl, video, label, minimapItem, minimapCanvas };
      rowCells[idx] = cell;
    }

    // Update video source
    if (cell.video.srcObject !== data.stream) {
      cell.video.srcObject = data.stream;
      cell.video
        .play()
        .catch((e) => console.log("Row video play error:", e));
    }

    // TRUE NATIVE SIZE - no scaling whatsoever for 100% sharpness
    const info = data.info;
    if (info?.width && info?.height) {
      cell.video.style.width = info.width + "px";
      cell.video.style.height = info.height + "px";
    } else {
      // Use video's native dimensions if no info
      cell.video.style.width = "auto";
      cell.video.style.height = "auto";
    }

    // Update label
    cell.label.textContent =
      info?.windowName || info?.appName || `Stream ${idx + 1}`;

    // Update classes
    cell.cell.classList.toggle("selected", idx === selectedGridIndex);
    cell.cell.classList.toggle(
      "sharer-focused",
      idx === sharerFocusedIndex,
    );
    cell.minimapItem.classList.toggle(
      "sharer-focused",
      idx === sharerFocusedIndex,
    );

    // Ensure cell is in the DOM
    if (!cell.cell.parentNode) {
      videoRow.appendChild(cell.cell);
    }

    // Ensure minimap item is in the DOM
    if (!cell.minimapItem.parentNode) {
      rowMinimap.appendChild(cell.minimapItem);
    }
  }

  // Reorder cells
  for (const idx of sortedOrder) {
    if (rowCells[idx]) {
      videoRow.appendChild(rowCells[idx].cell);
      rowMinimap.appendChild(rowCells[idx].minimapItem);
    }
  }

  // Show minimap if we have content
  rowMinimap.classList.toggle("visible", count > 0);

  // Update minimap thumbnails
  updateRowMinimap();
}

// Row minimap update
let rowMinimapInterval = null;

function updateRowMinimap() {
  const sortedOrder = [...streamOrder].sort((a, b) => a - b);

  for (const idx of sortedOrder) {
    const cell = rowCells[idx];
    if (!cell || !cell.video || !cell.minimapCanvas) continue;

    const video = cell.video;
    const canvas = cell.minimapCanvas;

    // Only draw if video has dimensions
    if (video.videoWidth && video.videoHeight) {
      const aspectRatio = video.videoWidth / video.videoHeight;
      const height = 36;
      const width = height * aspectRatio;

      canvas.width = width;
      canvas.height = height;
      canvas.style.width = width + "px";
      canvas.style.height = height + "px";

      const ctx = canvas.getContext("2d");
      ctx.drawImage(video, 0, 0, width, height);
    }

    // Update in-view state
    const cellRect = cell.cell.getBoundingClientRect();
    const containerRect = videoRow.getBoundingClientRect();
    const isInView =
      cellRect.left < containerRect.right &&
      cellRect.right > containerRect.left;
    cell.minimapItem.classList.toggle("in-view", isInView);
  }
}

function startRowMinimapUpdates() {
  if (rowMinimapInterval) return;
  rowMinimapInterval = setInterval(() => {
    if (
      currentLayout === "row" &&
      rowMinimap.classList.contains("visible")
    ) {
      updateRowMinimap();
    }
  }, 200);
}

function stopRowMinimapUpdates() {
  if (rowMinimapInterval) {
    clearInterval(rowMinimapInterval);
    rowMinimapInterval = null;
  }
}

// Row drag-to-scroll
let rowDragState = {
  isDragging: false,
  startX: 0,
  startY: 0,
  scrollLeft: 0,
  scrollTop: 0,
};

videoRow.addEventListener("mousedown", (e) => {
  // Don't start drag if clicking on a video cell's interactive area
  if (e.target.closest(".row-cell-label")) return;

  rowDragState.isDragging = true;
  rowDragState.startX = e.pageX - videoRow.offsetLeft;
  rowDragState.startY = e.pageY - videoRow.offsetTop;
  rowDragState.scrollLeft = videoRow.scrollLeft;
  rowDragState.scrollTop = videoRow.scrollTop;
  videoRow.classList.add("dragging");
});

document.addEventListener("mousemove", (e) => {
  if (!rowDragState.isDragging) return;
  e.preventDefault();

  const x = e.pageX - videoRow.offsetLeft;
  const y = e.pageY - videoRow.offsetTop;
  const walkX = (x - rowDragState.startX) * 1.5;
  const walkY = (y - rowDragState.startY) * 1.5;

  videoRow.scrollLeft = rowDragState.scrollLeft - walkX;
  videoRow.scrollTop = rowDragState.scrollTop - walkY;
});

document.addEventListener("mouseup", () => {
  rowDragState.isDragging = false;
  videoRow.classList.remove("dragging");
});

// Touch support for row drag
videoRow.addEventListener(
  "touchstart",
  (e) => {
    if (e.touches.length !== 1) return;
    const touch = e.touches[0];

    rowDragState.isDragging = true;
    rowDragState.startX = touch.pageX - videoRow.offsetLeft;
    rowDragState.startY = touch.pageY - videoRow.offsetTop;
    rowDragState.scrollLeft = videoRow.scrollLeft;
    rowDragState.scrollTop = videoRow.scrollTop;
  },
  { passive: true },
);

videoRow.addEventListener(
  "touchmove",
  (e) => {
    if (!rowDragState.isDragging || e.touches.length !== 1) return;
    const touch = e.touches[0];

    const x = touch.pageX - videoRow.offsetLeft;
    const y = touch.pageY - videoRow.offsetTop;
    const walkX = x - rowDragState.startX;
    const walkY = y - rowDragState.startY;

    videoRow.scrollLeft = rowDragState.scrollLeft - walkX;
    videoRow.scrollTop = rowDragState.scrollTop - walkY;
  },
  { passive: true },
);

videoRow.addEventListener("touchend", () => {
  rowDragState.isDragging = false;
});

// Update layout on resize
window.addEventListener("resize", () => {
  if (currentLayout === "row") {
    updateRowLayout();
  }
  // Update native mode centering on resize
  if (currentScale === "native") {
    updatePanZoomState();
  }
});

// Start row minimap updates
startRowMinimapUpdates();

// ==========================================
// Pan/Zoom for Native View
// ==========================================

function updatePanZoomState() {
  const video = mainVideo;
  if (!video.videoWidth || !video.videoHeight) {
    canPan = false;
    panZoomContainer.classList.remove("can-pan");
    minimap.classList.remove("visible");
    return;
  }

  const containerRect = mainVideoContainer.getBoundingClientRect();
  // Use intrinsic video dimensions (what native mode renders at)
  const videoWidth = video.videoWidth;
  const videoHeight = video.videoHeight;

  // Check if content exceeds viewport in native mode
  canPan =
    currentScale === "native" &&
    (videoWidth > containerRect.width ||
      videoHeight > containerRect.height);

  panZoomContainer.classList.toggle("can-pan", canPan);

  if (canPan) {
    // Calculate bounds - 0 is top-left, negative values pan to see more content
    const maxX = Math.max(0, videoWidth - containerRect.width);
    const maxY = Math.max(0, videoHeight - containerRect.height);

    // Clamp to bounds (0 = top-left, -maxX/Y = bottom-right)
    panZoomState.translateX = Math.max(
      -maxX,
      Math.min(0, panZoomState.translateX),
    );
    panZoomState.translateY = Math.max(
      -maxY,
      Math.min(0, panZoomState.translateY),
    );

    applyPanZoomTransform();
    updateMinimap();
    minimap.classList.add("visible");
  } else {
    // Reset transform
    panZoomState.translateX = 0;
    panZoomState.translateY = 0;
    applyPanZoomTransform();
    minimap.classList.remove("visible");
  }

  // Update follow toggle visibility (depends on canPan for cursor following)
  updateLayoutSelectorVisibility();
}

function applyPanZoomTransform() {
  if (
    currentScale === "native" &&
    mainVideo.videoWidth &&
    mainVideo.videoHeight
  ) {
    const videoWidth = mainVideo.videoWidth;
    const videoHeight = mainVideo.videoHeight;

    // Use cached dimensions during panning to avoid expensive getBoundingClientRect
    let containerWidth, containerHeight;
    if (panZoomState.isPanning && panZoomState.containerWidth > 0) {
      containerWidth = panZoomState.containerWidth;
      containerHeight = panZoomState.containerHeight;
    } else {
      const containerRect = mainVideoContainer.getBoundingClientRect();
      containerWidth = containerRect.width;
      containerHeight = containerRect.height;
    }

    // Only center if video is SMALLER than viewport
    // For large videos, start at (0,0) and allow panning
    const fitsX = videoWidth <= containerWidth;
    const fitsY = videoHeight <= containerHeight;

    const centerX = fitsX ? (containerWidth - videoWidth) / 2 : 0;
    const centerY = fitsY ? (containerHeight - videoHeight) / 2 : 0;

    // Apply centering (for small) + pan offset (for large)
    const x = centerX + panZoomState.translateX;
    const y = centerY + panZoomState.translateY;
    // Use translate3d for GPU compositing
    panZoomContent.style.transform = `translate3d(${x}px, ${y}px, 0)`;
  } else {
    panZoomContent.style.transform = "";
  }
}

// Cache for minimap to avoid recalculating on every frame
let minimapCache = { width: 0, height: 0, aspectRatio: 0 };

function updateMinimap() {
  if (!canPan || !mainVideo.videoWidth) return;

  const video = mainVideo;
  const videoWidth = video.videoWidth;
  const videoHeight = video.videoHeight;

  // Use cached container dimensions during panning
  let containerWidth, containerHeight;
  if (panZoomState.isPanning && panZoomState.containerWidth > 0) {
    containerWidth = panZoomState.containerWidth;
    containerHeight = panZoomState.containerHeight;
  } else {
    const containerRect = mainVideoContainer.getBoundingClientRect();
    containerWidth = containerRect.width;
    containerHeight = containerRect.height;
  }

  // Only update canvas size if aspect ratio changed
  const aspectRatio = videoWidth / videoHeight;
  const minimapWidth = 120;
  const minimapHeight = Math.round(minimapWidth / aspectRatio);

  if (minimapCache.aspectRatio !== aspectRatio) {
    minimapCanvas.width = minimapWidth;
    minimapCanvas.height = minimapHeight;
    minimapCanvas.style.height = minimapHeight + "px";
    minimapCache.aspectRatio = aspectRatio;
    minimapCache.width = minimapWidth;
    minimapCache.height = minimapHeight;
  }

  // Draw video frame to minimap
  const ctx = minimapCanvas.getContext("2d");
  ctx.drawImage(video, 0, 0, minimapWidth, minimapHeight);

  // Calculate viewport rectangle using intrinsic dimensions
  const scaleX = minimapWidth / videoWidth;
  const scaleY = minimapHeight / videoHeight;

  // Viewport position on video: 0 = top-left, negative pan shows more content
  const viewportX = Math.max(0, -panZoomState.translateX) * scaleX;
  const viewportY = Math.max(0, -panZoomState.translateY) * scaleY;
  const viewportW = containerWidth * scaleX;
  const viewportH = containerHeight * scaleY;

  minimapViewport.style.left = viewportX + "px";
  minimapViewport.style.top = viewportY + "px";
  minimapViewport.style.width = Math.min(viewportW, minimapWidth) + "px";
  minimapViewport.style.height =
    Math.min(viewportH, minimapHeight) + "px";
}

function startMinimapUpdates() {
  if (minimapUpdateInterval) return;
  minimapUpdateInterval = setInterval(() => {
    if (canPan && minimap.classList.contains("visible")) {
      updateMinimap();
    }
  }, 200);
}

function stopMinimapUpdates() {
  if (minimapUpdateInterval) {
    clearInterval(minimapUpdateInterval);
    minimapUpdateInterval = null;
  }
}

// Pan/zoom event handlers
function handlePanStart(e) {
  if (!canPan) return;

  // Cache dimensions at pan start (avoid getBoundingClientRect in move handler)
  const containerRect = mainVideoContainer.getBoundingClientRect();
  panZoomState.containerWidth = containerRect.width;
  panZoomState.containerHeight = containerRect.height;
  panZoomState.maxX = Math.max(0, mainVideo.videoWidth - containerRect.width);
  panZoomState.maxY = Math.max(0, mainVideo.videoHeight - containerRect.height);

  panZoomState.isPanning = true;
  panZoomContainer.classList.add("panning");

  const point = e.touches ? e.touches[0] : e;
  panZoomState.startX = point.clientX - panZoomState.translateX;
  panZoomState.startY = point.clientY - panZoomState.translateY;

  e.preventDefault();
}

function handlePanMove(e) {
  if (!panZoomState.isPanning) return;

  const point = e.touches ? e.touches[0] : e;

  // Use cached bounds for performance
  panZoomState.translateX = Math.max(
    -panZoomState.maxX,
    Math.min(0, point.clientX - panZoomState.startX),
  );
  panZoomState.translateY = Math.max(
    -panZoomState.maxY,
    Math.min(0, point.clientY - panZoomState.startY),
  );

  // Throttle visual update to animation frame
  if (!panZoomState.rafId) {
    panZoomState.rafId = requestAnimationFrame(() => {
      applyPanZoomTransform();
      updateMinimap();
      panZoomState.rafId = null;
    });
  }

  e.preventDefault();
}

function handlePanEnd(e) {
  panZoomState.isPanning = false;
  panZoomContainer.classList.remove("panning");

  // Cancel pending RAF and do final update
  if (panZoomState.rafId) {
    cancelAnimationFrame(panZoomState.rafId);
    panZoomState.rafId = null;
  }
  applyPanZoomTransform();
}

// Set up pan/zoom listeners
panZoomContainer.addEventListener("mousedown", handlePanStart);
document.addEventListener("mousemove", handlePanMove);
document.addEventListener("mouseup", handlePanEnd);

panZoomContainer.addEventListener("touchstart", handlePanStart, {
  passive: false,
});
document.addEventListener("touchmove", handlePanMove, { passive: false });
document.addEventListener("touchend", handlePanEnd);

// Update pan state when scale changes or video loads
mainVideo.addEventListener("loadedmetadata", () => {
  setTimeout(updatePanZoomState, 100);
});

mainVideo.addEventListener("resize", updatePanZoomState);

// ==========================================
// Layout Event Listeners
// ==========================================

// Layout buttons
document.querySelectorAll(".layout-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    setLayout(btn.dataset.layout);
  });
});

// Proportional toggle
proportionalSwitch.addEventListener("click", toggleProportionalSizing);

// Follow mode toggle
followSwitch.addEventListener("click", toggleFollowMode);

// ==========================================
// Keyboard Shortcuts (updated)
// ==========================================

document.addEventListener("keydown", (e) => {
  // Ignore if typing in an input
  if (e.target.tagName === "INPUT") return;

  switch (e.key.toLowerCase()) {
    case "f":
      toggleFullscreen();
      break;
    case "p":
      togglePiP();
      break;
    case "m":
      toggleAudio().catch(failViewer);
      break;
    case "g":
      if (streamOrder.length > 1) {
        toggleLayout();
      }
      break;
    case "e":
      if (currentLayout === "grid") {
        toggleProportionalSizing();
      }
      break;
    case "i":
      showStats = !showStats;
      document
        .getElementById("btn-stats")
        .classList.toggle("active", showStats);
      statsPanel.classList.toggle("visible", showStats);
      break;
    case "1":
      setScaleMode("fit");
      break;
    case "2":
      setScaleMode("fill");
      break;
    case "3":
      setScaleMode("native");
      break;
    case "?":
      shortcutsHelp.classList.toggle("visible");
      break;
    case "escape":
      if (document.fullscreenElement) {
        document.exitFullscreen();
      } else if (document.pictureInPictureElement) {
        document.exitPictureInPicture();
      }
      break;
    case "arrowleft":
    case "arrowup":
      if (currentLayout === "grid" && streamOrder.length > 0) {
        const currentIdx = streamOrder.indexOf(selectedGridIndex);
        const newIdx =
          currentIdx <= 0 ? streamOrder.length - 1 : currentIdx - 1;
        selectGridCell(streamOrder[newIdx]);
      }
      break;
    case "arrowright":
    case "arrowdown":
      if (currentLayout === "grid" && streamOrder.length > 0) {
        const currentIdx = streamOrder.indexOf(selectedGridIndex);
        const newIdx =
          currentIdx >= streamOrder.length - 1 ? 0 : currentIdx + 1;
        selectGridCell(streamOrder[newIdx]);
      }
      break;
    case "enter":
      if (currentLayout === "grid" && selectedGridIndex !== null) {
        viewerFocusedIndex = selectedGridIndex;
        setLayout("focus");
      }
      break;
  }
});

function setScaleMode(mode) {
  currentScale = mode;
  mainVideo.className = `main-video scale-${mode}`;

  // Toggle native-mode class for absolute positioning
  panZoomContent.classList.toggle("native-mode", mode === "native");

  // Update scale buttons
  document.querySelectorAll(".scale-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.scale === mode);
  });

  // Update grid cell videos too
  for (const idx in gridCells) {
    gridCells[idx].video.style.objectFit =
      mode === "fill" ? "cover" : "contain";
  }

  // Update pan/zoom state
  setTimeout(updatePanZoomState, 50);
}

// Scale button event listeners
document.querySelectorAll(".scale-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    setScaleMode(btn.dataset.scale);
  });
});

// Control button event listeners
document
  .getElementById("btn-fullscreen")
  .addEventListener("click", toggleFullscreen);
document.getElementById("btn-pip").addEventListener("click", togglePiP);
audioButton.addEventListener("click", () => toggleAudio().catch(failViewer));
audioUnlock.addEventListener("click", async () => {
  audioMuted = false;
  localStorage.setItem("clip-live-share-audio-muted", "0");
  syncAudioControls();
  await attemptAudioPlayback({ userGesture: true });
});
audioVolume.addEventListener("input", () => {
  const value = Math.max(0, Math.min(100, Number(audioVolume.value) || 0));
  systemAudio.volume = value / 100;
  localStorage.setItem("clip-live-share-audio-volume", String(value));
});
document.getElementById("btn-stats").addEventListener("click", () => {
  showStats = !showStats;
  document
    .getElementById("btn-stats")
    .classList.toggle("active", showStats);
  statsPanel.classList.toggle("visible", showStats);
});
document.getElementById("btn-help").addEventListener("click", () => {
  shortcutsHelp.classList.toggle("visible");
});

// Double-click to fullscreen
mainVideoContainer.addEventListener("dblclick", toggleFullscreen);

// Start minimap updates
startMinimapUpdates();

async function boot() {
  try {
    const pathComponents = window.location.pathname
      .split("/")
      .filter(Boolean);
    roomCode = normalizeRoom(decodeURIComponent(pathComponents.at(-1) || ""));
    viewerFragment = parseViewerFragment();
    roomCodeEl.textContent = roomCode;
    waitingRoom.textContent = roomCode;
    passwordRoomCode.textContent = roomCode;
    document.title = roomCode + " — Clip Live Share";

    audioMuted = initialAudioMuted(
      localStorage.getItem("clip-live-share-audio-muted"),
    );
    const storedVolume = Number(localStorage.getItem("clip-live-share-audio-volume"));
    if (Number.isFinite(storedVolume) && storedVolume >= 0 && storedVolume <= 100) {
      audioVolume.value = String(storedVolume);
    }
    syncAudioControls();
    await connect();
  } catch (error) {
    failViewer(error);
  }
}

boot();
