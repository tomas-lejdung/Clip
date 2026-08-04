import { ClipWebRoomSession } from "./clip-room-session.js";
import { ClipWebDiagnosticsSampler, formatWebDiagnostics } from "./clip-web-diagnostics.js";
import {
  createAnimationFrameCoalescer,
  nativeManualPanGeometry,
  nativeMinimapGeometry,
  nativePanGeometry,
  participantConnectionState,
  snapToDevicePixel,
  unsupportedEncodingPresentation,
} from "./clip-viewer-state.js";

const elements = Object.fromEntries([
  "room-heading", "room-label", "room-status", "top-actions", "controlbar", "participant-count", "audio-unlock", "participants-button", "fullscreen-button", "leave-button",
  "stage", "focus-view", "focus-surface", "focus-video", "row-view", "source-filmstrip",
  "native-minimap", "native-minimap-image", "native-minimap-viewport", "empty-state", "state-title", "state-message",
  "access-form", "access-word", "unsupported", "follow-select", "source-summary", "master-mute", "master-volume",
  "participants-panel", "participants-close", "participants-list", "unsupported-title", "unsupported-message",
  "diagnostics-button", "diagnostics-panel", "diagnostics-close", "diagnostics-copy", "diagnostics-summary", "diagnostics-list",
  "terminal-actions", "rejoin-button",
].map((id) => [id.replaceAll("-", "_"), document.getElementById(id)]));

let session = null;
let audioUnlocked = false;
let masterMuted = true;
const participantAudio = new Map();
const videoElements = new Map();
const thumbnailElements = new Map();
const HUD_IDLE_MILLISECONDS = 3_000;
const MANUAL_FOLLOW_VALUE = "manual";
let hudTimeout = null;
let minimapTimer = null;
let diagnosticsTimer = null;
let diagnosticsGeneration = 0;
let diagnosticsRefreshPending = false;
let latestDiagnostics = null;
let panGesture = null;
let revealHUD = () => {};
let hadRenderableMedia = false;
const diagnosticsSampler = new ClipWebDiagnosticsSampler();
const scheduleMotionRender = createAnimationFrameCoalescer(() => {
  if (session && !session.closed && session.state === "connected") renderMotionPresentation();
});
const handleViewportChange = () => scheduleMotionRender();
const stageResizeObserver = new ResizeObserver(handleViewportChange);

void start();
stageResizeObserver.observe(elements.stage);
window.addEventListener("resize", handleViewportChange);

async function start() {
  try {
    session = await ClipWebRoomSession.bootstrap(window.location.href, browserDisplayName());
    elements.room_label.textContent = session.invite.roomCode;
    session.addEventListener("state", (event) => renderRoomState(event.detail));
    session.addEventListener("roster", render);
    session.media.addEventListener("change", (event) => {
      if (session.closed) return;
      if (event.detail?.reason === "cursor") scheduleMotionRender();
      else render();
    });
    bindControls();
    await session.connect();
  } catch (error) {
    setHeaderStatus("Unavailable", "error");
    showState("Couldn’t Join Live Share", String(error?.message ?? error));
  }
}

function browserDisplayName() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "Browser";
  return `${platform} Web Viewer`.slice(0, 80);
}

function bindControls() {
  document.querySelectorAll("[data-layout]").forEach((button) => button.addEventListener("click", () => {
    session.media.setLayout(button.dataset.layout);
  }));
  document.querySelectorAll("[data-scale]").forEach((button) => button.addEventListener("click", () => {
    session.media.setScaleMode(button.dataset.scale);
  }));
  elements.follow_select.addEventListener("change", () => {
    const value = elements.follow_select.value;
    session.media.followParticipant(value === MANUAL_FOLLOW_VALUE ? null : value);
  });
  elements.participants_button.addEventListener("click", () => {
    closeDiagnostics(); elements.participants_panel.hidden = false; revealHUD();
  });
  elements.participants_close.addEventListener("click", () => { elements.participants_panel.hidden = true; revealHUD(); });
  elements.diagnostics_button.addEventListener("click", openDiagnostics);
  elements.diagnostics_close.addEventListener("click", closeDiagnostics);
  elements.diagnostics_copy.addEventListener("click", () => void copyDiagnostics());
  elements.fullscreen_button.addEventListener("click", async () => {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  });
  document.addEventListener("fullscreenchange", () => {
    elements.fullscreen_button.textContent = document.fullscreenElement ? "Exit Fullscreen" : "Fullscreen";
    scheduleMotionRender();
  });
  elements.leave_button.addEventListener("click", () => session.close());
  elements.rejoin_button.addEventListener("click", () => window.location.reload());
  elements.audio_unlock.addEventListener("click", () => {
    audioUnlocked = true; masterMuted = false; syncAudio();
  });
  elements.master_mute.addEventListener("click", () => { masterMuted = !masterMuted; syncAudio(); });
  elements.master_volume.addEventListener("input", syncAudio);
  elements.access_form.addEventListener("submit", (event) => {
    event.preventDefault();
    void session.retryAdmission(elements.access_word.value).catch((error) => showState("Couldn’t Join", String(error?.message ?? error), true));
  });
  bindHUDVisibility();
  bindFocusPanning();
  bindRowPanning();
  // A refresh deliberately keeps the tab-scoped identity and reconnect
  // credential. The WebSocket closes naturally and the next page consumes a
  // one-time reconnect ticket; only the explicit Leave action removes state.
}

function renderRoomState({ state, message }) {
  setTerminalUI(state === "left" || state === "ended");
  switch (state) {
    case "connected": setHeaderStatus("Connected", "connected"); render(); break;
    case "waiting": setHeaderStatus("Waiting", "waiting"); showState("Waiting for approval", message || "The room is checking this invite."); break;
    case "access-word": setHeaderStatus("Access word required", "waiting"); showState("Access Word Required", message || "Enter the room Access Word.", true); break;
    case "denied": setHeaderStatus("Denied", "error"); showState("Request Denied", message || "The room owner denied this browser."); break;
    case "full": setHeaderStatus("Room full", "error"); showState("Room Is Full", message); break;
    case "ended": setHeaderStatus("Ended", "error"); showState("Live Share Ended", message); break;
    case "left": setHeaderStatus("Left", "waiting"); showState("You left the room", message || "This browser is no longer connected. Join again or close this tab when you are finished."); break;
    case "reconnecting": setHeaderStatus("Reconnecting", "waiting"); showState("Reconnecting…", message); break;
    case "reconnect-failed": setHeaderStatus("Reconnect failed", "error"); showState("Couldn’t Reconnect", message); break;
    case "error": setHeaderStatus("Connection issue", "error"); showState("Connection Issue", message); break;
    default: setHeaderStatus("Joining", "joining"); showState("Joining Live Share…", message || "Preparing encrypted peer connections.");
  }
}

function setTerminalUI(isTerminal) {
  elements.top_actions.hidden = isTerminal;
  elements.controlbar.hidden = isTerminal;
  elements.terminal_actions.hidden = !isTerminal;
  if (!isTerminal) return;
  elements.participants_panel.hidden = true;
  closeDiagnostics();
  clearTimeout(hudTimeout);
  document.body.classList.remove("hud-hidden");
  elements.source_filmstrip.hidden = true;
  elements.native_minimap.hidden = true;
  elements.unsupported.hidden = true;
}

function setHeaderStatus(label, state) {
  elements.room_status.textContent = label;
  elements.room_heading.dataset.state = state;
}

function showState(title, message, accessWord = false) {
  scheduleMotionRender.cancel();
  elements.empty_state.hidden = false;
  elements.state_title.textContent = title;
  elements.state_message.textContent = message || "";
  elements.access_form.hidden = !accessWord;
  elements.focus_view.hidden = true;
  elements.row_view.hidden = true;
  elements.source_filmstrip.hidden = true;
  elements.native_minimap.hidden = true;
}

function render() {
  if (!session || session.closed || session.state !== "connected") return;
  scheduleMotionRender.cancel();
  renderParticipants();
  renderFollowSelector();
  renderLayout();
  renderAudio();
  renderUnsupported();
}

function renderParticipants() {
  const members = [...session.media.participants.values()];
  elements.participant_count.textContent = String(members.length);
  elements.participants_list.replaceChildren(...members.map((member) => {
    const participantID = member.descriptor.participantID;
    const state = participantConnectionState(member, session.media.peerStates.get(participantID));
    const row = document.createElement("article");
    row.className = "participant";
    const main = document.createElement("div"); main.className = "participant-main";
    const dot = document.createElement("span"); dot.className = `presence ${state.state === "p2p" ? "p2p" : ""}`;
    const name = document.createElement("div"); name.className = "participant-name";
    const strong = document.createElement("strong"); strong.textContent = member.descriptor.displayName;
    const subtitle = document.createElement("span"); subtitle.textContent = [member.isCreator ? "Room creator" : null, member.isLocal ? "This browser" : state.state === "p2p" ? "P2P" : state.state].filter(Boolean).join(" · ");
    name.append(strong, subtitle);
    const badge = document.createElement("span"); badge.className = "badge"; badge.textContent = member.descriptor.clientKind === "webViewer" ? "WEB" : "NATIVE";
    main.append(dot, name, badge); row.append(main);
    if (!member.isLocal && session.media.audioTracks.has(participantID)) row.append(makeParticipantAudioControl(participantID));
    return row;
  }));
}

function makeParticipantAudioControl(participantID) {
  const control = document.createElement("div"); control.className = "audio-control";
  const button = document.createElement("button"); button.className = "icon-button"; button.type = "button";
  const state = participantAudio.get(participantID) ?? { muted: false, volume: .8 };
  button.textContent = state.muted ? "Muted" : "Audio";
  button.addEventListener("click", () => { state.muted = !state.muted; participantAudio.set(participantID, state); syncAudio(); renderParticipants(); });
  const range = document.createElement("input"); range.type = "range"; range.min = "0"; range.max = "1"; range.step = ".01"; range.value = String(state.volume);
  range.setAttribute("aria-label", "Participant volume");
  range.addEventListener("input", () => { state.volume = Number(range.value); participantAudio.set(participantID, state); syncAudio(); });
  control.append(button, range); return control;
}

function renderFollowSelector() {
  const selected = session.media.followEnabled
    ? session.media.followParticipantID ?? MANUAL_FOLLOW_VALUE
    : MANUAL_FOLLOW_VALUE;
  const options = [new Option("Off · Manual", MANUAL_FOLLOW_VALUE)];
  for (const participantID of session.media.participantOrder) {
    const member = session.media.participants.get(participantID);
    const count = session.media.sourcesByParticipant.get(participantID)?.sources.filter((source) => source.active).length ?? 0;
    if (!member?.isLocal && count > 0) options.push(new Option(`${member.descriptor.displayName} (${count})`, participantID));
  }
  elements.follow_select.replaceChildren(...options);
  elements.follow_select.value = selected;
}

function renderLayout() {
  const media = session.media;
  const sources = media.renderableSources();
  const hasRenderableMedia = sources.length > 0;
  if (hasRenderableMedia && !hadRenderableMedia) revealHUD();
  hadRenderableMedia = hasRenderableMedia;
  document.querySelectorAll("[data-layout]").forEach((button) => button.classList.toggle("active", button.dataset.layout === media.layout));
  document.querySelectorAll("[data-scale]").forEach((button) => button.classList.toggle("active", button.dataset.scale === media.scaleMode));
  elements.empty_state.hidden = sources.length > 0;
  if (sources.length === 0) {
    elements.state_title.textContent = "Waiting for a shared window";
    elements.state_message.textContent = "Connected participants are not sharing video yet.";
  }
  elements.focus_view.hidden = media.layout !== "focus" || sources.length === 0;
  elements.row_view.hidden = media.layout !== "row" || sources.length === 0;
  if (media.layout === "focus") {
    renderFocus(media.renderableSelectedSource());
    renderFilmstrip(sources);
  } else {
    elements.source_filmstrip.hidden = true;
    elements.native_minimap.hidden = true;
    elements.source_summary.textContent = `${sources.length} shared ${sources.length === 1 ? "window" : "windows"}`;
    elements.row_view.classList.toggle("manual-pan", !media.followEnabled);
    renderRow(sources);
  }
}

function renderMotionPresentation() {
  if (!session || session.closed || session.state !== "connected") return;
  if (session.media.layout === "focus") applyFocusPresentation(session.media.renderableSelectedSource());
  else if (session.media.followEnabled) followRowSource(session.media.renderableSelectedSource());
}

function renderFocus(source) {
  const track = session.media.trackForSource(source);
  setVideoTrack(elements.focus_video, track);
  applyFocusPresentation(source);
  elements.source_summary.textContent = source ? sourceLabel(source) : "Waiting for a shared window";
}

function renderRow(sources) {
  const keys = new Set(sources.map((source) => source.key));
  const manualSelectionKey = session.media.followEnabled ? null : session.media.selectedSource()?.key ?? null;
  for (const [key, card] of videoElements) {
    if (!keys.has(key)) { card.remove(); videoElements.delete(key); }
  }
  for (const source of sources) {
    let card = videoElements.get(source.key);
    if (!card) {
      card = document.createElement("article"); card.className = "media-card";
      const video = document.createElement("video"); video.autoplay = true; video.playsInline = true; video.muted = true;
      const label = document.createElement("span"); label.className = "media-label";
      card.append(video, label);
      card.tabIndex = 0;
      card.addEventListener("click", () => selectSourceManually(card.dataset.sourceKey));
      card.addEventListener("dblclick", () => { selectSourceManually(card.dataset.sourceKey); session.media.setLayout("focus"); });
      card.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault(); selectSourceManually(card.dataset.sourceKey); session.media.setLayout("focus");
      });
      videoElements.set(source.key, card);
    }
    card.dataset.sourceKey = source.key;
    card.querySelector(".media-label").textContent = sourceLabel(source);
    card.classList.toggle("publisher-focused", source.focused);
    card.classList.toggle("viewer-selected", source.key === manualSelectionKey);
    setVideoTrack(card.querySelector("video"), session.media.trackForSource(source));
    applyRowPresentation(card, source);
  }
  elements.row_view.replaceChildren(...sources.map((source) => videoElements.get(source.key)));
  if (session.media.followEnabled) followRowSource(session.media.renderableSelectedSource());
}

function followRowSource(source) {
  const card = source ? videoElements.get(source.key) : null;
  if (!source || !card) return;
  const cursor = session.media.cursorForSource(source) ?? { x: .5, y: .5 };
  const viewportWidth = elements.row_view.clientWidth;
  const viewportHeight = elements.row_view.clientHeight;
  const pointX = card.offsetLeft + cursor.x * source.sourcePointWidth;
  const pointY = card.offsetTop + cursor.y * source.sourcePointHeight;
  const targetLeft = source.sourcePointWidth > viewportWidth
    ? pointX - viewportWidth / 2
    : card.offsetLeft - (viewportWidth - source.sourcePointWidth) / 2;
  const targetTop = source.sourcePointHeight > viewportHeight
    ? pointY - viewportHeight / 2
    : card.offsetTop - (viewportHeight - source.sourcePointHeight) / 2;
  elements.row_view.scrollLeft = Math.max(0, Math.min(elements.row_view.scrollWidth - viewportWidth, targetLeft));
  elements.row_view.scrollTop = Math.max(0, Math.min(elements.row_view.scrollHeight - viewportHeight, targetTop));
}

function applyFocusPresentation(source) {
  const mode = session.media.scaleMode;
  const viewport = elements.focus_view;
  const surface = elements.focus_surface;
  if (!source) {
    elements.native_minimap.hidden = true;
    return;
  }
  const bounds = viewport.getBoundingClientRect();
  const sourceWidth = source.sourcePointWidth;
  const sourceHeight = source.sourcePointHeight;
  if (![bounds.width, bounds.height, sourceWidth, sourceHeight].every((value) => Number.isFinite(value) && value > 0)) return;
  surface.style.width = `${sourceWidth}px`;
  surface.style.height = `${sourceHeight}px`;

  if (mode !== "native") {
    const scale = mode === "fill"
      ? Math.max(bounds.width / sourceWidth, bounds.height / sourceHeight)
      : Math.min(bounds.width / sourceWidth, bounds.height / sourceHeight);
    const left = snapToDevicePixel((bounds.width - sourceWidth * scale) / 2, window.devicePixelRatio);
    const top = snapToDevicePixel((bounds.height - sourceHeight * scale) / 2, window.devicePixelRatio);
    surface.style.transform = `translate3d(${left}px, ${top}px, 0) scale(${scale})`;
    viewport.classList.remove("can-pan", "panning");
    elements.native_minimap.hidden = true;
    return;
  }

  const followsCursor = session.media.followEnabled;
  const geometry = followsCursor
    ? nativePanGeometry({ sourceWidth, sourceHeight, viewportWidth: bounds.width, viewportHeight: bounds.height, cursor: session.media.cursorForSource(source), devicePixelRatio: window.devicePixelRatio })
    : manualPanGeometry(source, bounds);
  if (!geometry) return;
  const left = geometry.left;
  const top = geometry.top;
  surface.style.transform = `translate3d(${left}px, ${top}px, 0)`;
  const canPan = sourceWidth > bounds.width || sourceHeight > bounds.height;
  viewport.classList.toggle("can-pan", canPan && !followsCursor);
  if (followsCursor) elements.native_minimap.hidden = true;
  else renderNativeMinimap({ left, top, width: sourceWidth, height: sourceHeight }, bounds);
}

function applyRowPresentation(card, source) {
  const video = card.querySelector("video");
  card.style.width = `${source.sourcePointWidth}px`;
  card.style.height = `${source.sourcePointHeight}px`;
  video.style.width = `${source.sourcePointWidth}px`;
  video.style.height = `${source.sourcePointHeight}px`;
}

function renderFilmstrip(sources) {
  const visibleKeys = new Set(sources.map((source) => source.key));
  for (const [key, thumbnail] of thumbnailElements) {
    if (!visibleKeys.has(key)) { thumbnail.remove(); thumbnailElements.delete(key); }
  }
  const selectedKey = session.media.followEnabled ? null : session.media.selectedSource()?.key ?? null;
  for (const source of sources) {
    let thumbnail = thumbnailElements.get(source.key);
    if (!thumbnail) {
      thumbnail = document.createElement("button");
      thumbnail.type = "button";
      thumbnail.className = "source-thumbnail";
      const video = document.createElement("video");
      video.autoplay = true; video.playsInline = true; video.muted = true;
      const label = document.createElement("span"); label.className = "source-thumbnail-label";
      const focus = document.createElement("span"); focus.className = "source-thumbnail-focus"; focus.setAttribute("aria-hidden", "true");
      thumbnail.append(video, label, focus);
      thumbnail.addEventListener("click", () => selectSourceManually(thumbnail.dataset.sourceKey));
      thumbnailElements.set(source.key, thumbnail);
    }
    thumbnail.dataset.sourceKey = source.key;
    thumbnail.setAttribute("aria-label", `View ${sourceLabel(source)}`);
    thumbnail.querySelector(".source-thumbnail-label").textContent = sourceLabel(source);
    thumbnail.classList.toggle("publisher-focused", source.focused);
    thumbnail.classList.toggle("viewer-selected", source.key === selectedKey);
    setVideoTrack(thumbnail.querySelector("video"), session.media.trackForSource(source));
  }
  elements.source_filmstrip.replaceChildren(...sources.map((source) => thumbnailElements.get(source.key)));
  elements.source_filmstrip.hidden = sources.length < 2;
}

function selectSourceManually(sourceKey) {
  if (!sourceKey) return;
  session.media.selectSource(sourceKey);
}

function manualPanGeometry(source, viewport) {
  const width = source.sourcePointWidth;
  const height = source.sourcePointHeight;
  const initial = session.media.nativePanForSource(source);
  const geometry = nativeManualPanGeometry({
    sourceWidth: width, sourceHeight: height,
    viewportWidth: viewport.width, viewportHeight: viewport.height,
    left: initial.left, top: initial.top, devicePixelRatio: window.devicePixelRatio,
  });
  if (!geometry) return null;
  session.media.setNativePanForSource(source.key, { left: geometry.left, top: geometry.top });
  return geometry;
}

function renderNativeMinimap(geometry, viewport) {
  const map = nativeMinimapGeometry({
    sourceWidth: geometry.width, sourceHeight: geometry.height,
    viewportWidth: viewport.width, viewportHeight: viewport.height,
    left: geometry.left, top: geometry.top,
    maximumWidth: 140, maximumHeight: 96, devicePixelRatio: window.devicePixelRatio,
  });
  elements.native_minimap.hidden = map === null;
  if (!map) return;

  const canvas = elements.native_minimap_image;
  const mapWidth = map.width;
  const mapHeight = map.height;
  const pixelRatio = Number.isFinite(window.devicePixelRatio) && window.devicePixelRatio > 0 ? window.devicePixelRatio : 1;
  const backingWidth = Math.max(1, Math.round(mapWidth * pixelRatio));
  const backingHeight = Math.max(1, Math.round(mapHeight * pixelRatio));
  if (canvas.width !== backingWidth || canvas.height !== backingHeight) {
    canvas.width = backingWidth; canvas.height = backingHeight;
  }
  canvas.style.width = `${mapWidth}px`; canvas.style.height = `${mapHeight}px`;
  if (elements.focus_video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
    canvas.getContext("2d")?.drawImage(elements.focus_video, 0, 0, backingWidth, backingHeight);
  }

  Object.assign(elements.native_minimap_viewport.style, {
    left: `${map.viewport.left}px`, top: `${map.viewport.top}px`,
    width: `${map.viewport.width}px`, height: `${map.viewport.height}px`,
  });
}

function bindHUDVisibility() {
  revealHUD = () => {
    document.body.classList.remove("hud-hidden");
    clearTimeout(hudTimeout);
    hudTimeout = setTimeout(() => {
      if (!elements.participants_panel.hidden || !elements.diagnostics_panel.hidden) return;
      if (!elements.focus_video.srcObject && elements.row_view.hidden) return;
      document.body.classList.add("hud-hidden");
    }, HUD_IDLE_MILLISECONDS);
  };
  for (const eventName of ["pointermove", "pointerdown", "keydown"]) document.addEventListener(eventName, revealHUD, { passive: true });
  window.addEventListener("pagehide", () => {
    clearTimeout(hudTimeout); clearInterval(minimapTimer); clearInterval(diagnosticsTimer); scheduleMotionRender.cancel();
    stageResizeObserver.disconnect(); window.removeEventListener("resize", handleViewportChange);
  }, { once: true });
  revealHUD();
}

function bindFocusPanning() {
  elements.focus_view.addEventListener("pointerdown", (event) => {
    const source = session?.media.selectedSource();
    if (event.button !== 0 || !source || session.media.layout !== "focus" || session.media.scaleMode !== "native" || session.media.followEnabled) return;
    const viewport = elements.focus_view.getBoundingClientRect();
    if (source.sourcePointWidth <= viewport.width && source.sourcePointHeight <= viewport.height) return;
    const pan = manualPanGeometry(source, viewport);
    panGesture = { pointerID: event.pointerId, sourceKey: source.key, startX: event.clientX, startY: event.clientY, left: pan.left, top: pan.top };
    elements.focus_view.setPointerCapture(event.pointerId);
    elements.focus_view.classList.add("panning");
    event.preventDefault();
  });
  elements.focus_view.addEventListener("pointermove", (event) => {
    if (!panGesture || panGesture.pointerID !== event.pointerId) return;
    const source = session.media.selectedSource();
    if (!source || source.key !== panGesture.sourceKey) return;
    const viewport = elements.focus_view.getBoundingClientRect();
    const geometry = nativeManualPanGeometry({
      sourceWidth: source.sourcePointWidth, sourceHeight: source.sourcePointHeight,
      viewportWidth: viewport.width, viewportHeight: viewport.height,
      left: panGesture.left + event.clientX - panGesture.startX,
      top: panGesture.top + event.clientY - panGesture.startY,
      devicePixelRatio: window.devicePixelRatio,
    });
    if (!geometry) return;
    session.media.setNativePanForSource(source.key, { left: geometry.left, top: geometry.top });
    scheduleMotionRender();
  });
  const finish = (event) => {
    if (!panGesture || panGesture.pointerID !== event.pointerId) return;
    panGesture = null; elements.focus_view.classList.remove("panning");
  };
  elements.focus_view.addEventListener("pointerup", finish);
  elements.focus_view.addEventListener("pointercancel", finish);
  minimapTimer = setInterval(() => {
    if (!elements.native_minimap.hidden && session?.state === "connected") scheduleMotionRender();
  }, 200);
}

function bindRowPanning() {
  let drag = null;
  elements.row_view.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || session.media.followEnabled) return;
    drag = { pointerID: event.pointerId, x: event.clientX, y: event.clientY, left: elements.row_view.scrollLeft, top: elements.row_view.scrollTop, moved: false };
    elements.row_view.setPointerCapture(event.pointerId);
  });
  elements.row_view.addEventListener("pointermove", (event) => {
    if (!drag || drag.pointerID !== event.pointerId) return;
    const dx = event.clientX - drag.x; const dy = event.clientY - drag.y;
    if (Math.abs(dx) + Math.abs(dy) > 5) drag.moved = true;
    if (!drag.moved) return;
    elements.row_view.classList.add("dragging");
    elements.row_view.scrollLeft = drag.left - dx;
    elements.row_view.scrollTop = drag.top - dy;
    event.preventDefault();
  });
  const finish = (event) => {
    if (!drag || drag.pointerID !== event.pointerId) return;
    if (drag.moved) elements.row_view.dataset.suppressClick = "true";
    drag = null; elements.row_view.classList.remove("dragging");
  };
  elements.row_view.addEventListener("pointerup", finish);
  elements.row_view.addEventListener("pointercancel", finish);
  elements.row_view.addEventListener("click", (event) => {
    if (elements.row_view.dataset.suppressClick !== "true") return;
    delete elements.row_view.dataset.suppressClick;
    event.preventDefault(); event.stopPropagation();
  }, true);
}

function sourceLabel(source) {
  const owner = session.media.participants.get(source.ownerParticipantID)?.descriptor.displayName ?? "Participant";
  const title = source.windowName || source.appName || "Shared Window";
  return `${owner} · ${title}`;
}

function setVideoTrack(video, track) {
  if (!track) { video.srcObject = null; return; }
  const current = video.srcObject?.getVideoTracks?.()[0];
  if (current === track) return;
  video.srcObject = new MediaStream([track]);
  void video.play().catch(() => {});
}

function renderAudio() {
  const activeParticipants = new Set(session.media.audioTracks.keys());
  document.querySelectorAll("audio[data-participant]").forEach((audio) => {
    if (!activeParticipants.has(audio.dataset.participant)) audio.remove();
  });
  for (const [participantID, track] of session.media.audioTracks) {
    let audio = document.querySelector(`audio[data-participant="${CSS.escape(participantID)}"]`);
    if (!audio) {
      audio = document.createElement("audio"); audio.dataset.participant = participantID; audio.autoplay = true;
      document.body.append(audio);
    }
    if (audio.srcObject?.getAudioTracks?.()[0] !== track) audio.srcObject = new MediaStream([track]);
  }
  syncAudio();
}

function syncAudio() {
  elements.audio_unlock.hidden = audioUnlocked;
  elements.master_mute.textContent = masterMuted ? "Muted" : "Audio On";
  const master = Number(elements.master_volume.value);
  document.querySelectorAll("audio[data-participant]").forEach((audio) => {
    const state = participantAudio.get(audio.dataset.participant) ?? { muted: false, volume: .8 };
    audio.muted = !audioUnlocked || masterMuted || state.muted;
    audio.volume = Math.max(0, Math.min(1, master * state.volume));
    if (audioUnlocked && !audio.muted) void audio.play().catch(() => { elements.audio_unlock.hidden = false; });
  });
}

function renderUnsupported() {
  const presentation = unsupportedEncodingPresentation(session.media.peerStates);
  elements.unsupported.hidden = presentation === null;
  if (!presentation) return;
  elements.unsupported_title.textContent = presentation.title;
  elements.unsupported_message.textContent = presentation.message;
}

function openDiagnostics() {
  elements.participants_panel.hidden = true;
  elements.diagnostics_panel.hidden = false;
  revealHUD();
  clearInterval(diagnosticsTimer);
  void refreshDiagnostics();
  diagnosticsTimer = setInterval(() => void refreshDiagnostics(), 1_000);
}

function closeDiagnostics() {
  elements.diagnostics_panel.hidden = true;
  clearInterval(diagnosticsTimer);
  diagnosticsTimer = null;
  diagnosticsGeneration += 1;
  revealHUD();
}

async function refreshDiagnostics() {
  if (!session || session.closed || elements.diagnostics_panel.hidden || diagnosticsRefreshPending) return;
  const generation = diagnosticsGeneration;
  diagnosticsRefreshPending = true;
  let snapshot;
  try {
    snapshot = await diagnosticsSampler.sample(session);
  } finally {
    diagnosticsRefreshPending = false;
  }
  if (generation !== diagnosticsGeneration || elements.diagnostics_panel.hidden) return;
  latestDiagnostics = snapshot;
  renderDiagnostics(snapshot);
}

function renderDiagnostics(snapshot) {
  elements.diagnostics_summary.replaceChildren(
    diagnosticMetric("Room", snapshot.roomCode),
    diagnosticMetric("Participants", snapshot.participantCount),
    diagnosticMetric("Direct Links", snapshot.directLinkCount),
    diagnosticMetric("Visible Sources", snapshot.activeSources),
  );
  if (snapshot.peers.length === 0) {
    const empty = document.createElement("p");
    empty.className = "diagnostics-empty";
    empty.textContent = "No remote peer connections yet.";
    elements.diagnostics_list.replaceChildren(empty);
    return;
  }
  elements.diagnostics_list.replaceChildren(...snapshot.peers.map(diagnosticPeerCard));
}

function diagnosticMetric(label, value) {
  const metric = document.createElement("div");
  const strong = document.createElement("strong"); strong.textContent = String(value);
  const span = document.createElement("span"); span.textContent = label;
  metric.append(strong, span);
  return metric;
}

function diagnosticPeerCard(peer) {
  const card = document.createElement("article");
  card.className = "diagnostics-peer";
  const heading = document.createElement("div"); heading.className = "diagnostics-peer-heading";
  const identity = document.createElement("div"); identity.className = "diagnostics-peer-name";
  const name = document.createElement("strong"); name.textContent = peer.displayName;
  const state = document.createElement("span"); state.textContent = peer.connectionState;
  identity.append(name, state);
  const badge = document.createElement("span"); badge.className = "badge"; badge.textContent = peer.clientKind;
  heading.append(identity, badge);

  const facts = document.createElement("dl"); facts.className = "diagnostics-facts";
  diagnosticFact(facts, "Route", [peer.route.label, peer.route.detail].filter(Boolean).join(" · "));
  diagnosticFact(facts, "RTT", diagnosticValue(peer.roundTripTimeMs, "ms"));
  diagnosticFact(facts, "ICE", peer.iceState);
  diagnosticFact(facts, "Control", peer.controlState);
  card.append(heading, facts);

  if (peer.error) {
    const error = document.createElement("p"); error.className = "diagnostics-error";
    error.textContent = peer.error; card.append(error);
  }
  const tracks = document.createElement("div"); tracks.className = "diagnostics-tracks";
  if (peer.tracks.length === 0) {
    const unavailable = document.createElement("p"); unavailable.textContent = "No incoming media statistics reported.";
    tracks.append(unavailable);
  } else {
    tracks.append(...peer.tracks.map(diagnosticTrack));
  }
  card.append(tracks);
  return card;
}

function diagnosticFact(list, label, value) {
  const term = document.createElement("dt"); term.textContent = label;
  const description = document.createElement("dd"); description.textContent = value || "Unavailable";
  list.append(term, description);
}

function diagnosticTrack(track) {
  const row = document.createElement("section"); row.className = "diagnostics-track";
  const heading = document.createElement("div"); heading.className = "diagnostics-track-heading";
  const name = document.createElement("strong"); name.textContent = track.label;
  const codec = document.createElement("span"); codec.textContent = track.codec ?? "Codec unavailable";
  heading.append(name, codec);
  const metrics = document.createElement("div"); metrics.className = "diagnostics-track-metrics";
  metrics.append(
    diagnosticTrackMetric("Resolution", track.width && track.height ? `${track.width}×${track.height}` : "Unavailable"),
    diagnosticTrackMetric("FPS", track.fps ?? "Unavailable"),
    diagnosticTrackMetric("Rate", diagnosticValue(track.bitrateKbps, "kbps")),
    diagnosticTrackMetric("Lost", track.packetsLost ?? "Unavailable"),
  );
  row.append(heading, metrics);
  return row;
}

function diagnosticTrackMetric(label, value) {
  const metric = document.createElement("span");
  const strong = document.createElement("strong"); strong.textContent = String(value);
  const small = document.createElement("small"); small.textContent = label;
  metric.append(strong, small);
  return metric;
}

function diagnosticValue(value, unit) {
  return typeof value === "number" && Number.isFinite(value) ? `${value} ${unit}` : "Unavailable";
}

async function copyDiagnostics() {
  if (!latestDiagnostics) await refreshDiagnostics();
  if (!latestDiagnostics) return;
  const original = elements.diagnostics_copy.textContent;
  try {
    await navigator.clipboard.writeText(formatWebDiagnostics(latestDiagnostics));
    elements.diagnostics_copy.textContent = "Copied";
  } catch {
    elements.diagnostics_copy.textContent = "Copy Failed";
  }
  setTimeout(() => { elements.diagnostics_copy.textContent = original; }, 1_500);
}
