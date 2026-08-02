import { ClipWebRoomSession } from "./clip-room-session.js";
import { createAnimationFrameCoalescer, nativePanGeometry, participantConnectionState, unsupportedEncodingPresentation } from "./clip-viewer-state.js";

const elements = Object.fromEntries([
  "room-label", "participant-count", "audio-unlock", "participants-button", "fullscreen-button", "leave-button",
  "stage", "focus-view", "focus-video", "grid-view", "row-view", "empty-state", "state-title", "state-message",
  "access-form", "access-word", "unsupported", "follow-select", "source-summary", "master-mute", "master-volume",
  "participants-panel", "participants-close", "participants-list", "unsupported-title", "unsupported-message",
].map((id) => [id.replaceAll("-", "_"), document.getElementById(id)]));

let session = null;
let audioUnlocked = false;
let masterMuted = true;
const participantAudio = new Map();
const videoElements = new Map();
const scheduleLayoutRender = createAnimationFrameCoalescer(() => {
  if (session && !session.closed && session.state === "connected") renderLayout();
});

void start();
new ResizeObserver(scheduleLayoutRender).observe(elements.stage);

async function start() {
  try {
    session = await ClipWebRoomSession.bootstrap(window.location.href, browserDisplayName());
    elements.room_label.textContent = `Room ${session.invite.roomCode} · WEB`;
    session.addEventListener("state", (event) => renderRoomState(event.detail));
    session.addEventListener("roster", render);
    session.media.addEventListener("change", (event) => {
      if (session.closed) return;
      if (event.detail?.reason === "cursor") scheduleLayoutRender();
      else render();
    });
    bindControls();
    await session.connect();
  } catch (error) {
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
  elements.follow_select.addEventListener("change", () => session.media.followParticipant(elements.follow_select.value || null));
  elements.participants_button.addEventListener("click", () => { elements.participants_panel.hidden = false; });
  elements.participants_close.addEventListener("click", () => { elements.participants_panel.hidden = true; });
  elements.fullscreen_button.addEventListener("click", async () => {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  });
  document.addEventListener("fullscreenchange", () => { elements.fullscreen_button.textContent = document.fullscreenElement ? "Exit Fullscreen" : "Fullscreen"; });
  elements.leave_button.addEventListener("click", () => session.close());
  elements.audio_unlock.addEventListener("click", () => {
    audioUnlocked = true; masterMuted = false; syncAudio();
  });
  elements.master_mute.addEventListener("click", () => { masterMuted = !masterMuted; syncAudio(); });
  elements.master_volume.addEventListener("input", syncAudio);
  elements.access_form.addEventListener("submit", (event) => {
    event.preventDefault();
    void session.retryAdmission(elements.access_word.value).catch((error) => showState("Couldn’t Join", String(error?.message ?? error), true));
  });
  // A refresh deliberately keeps the tab-scoped identity and reconnect
  // credential. The WebSocket closes naturally and the next page consumes a
  // one-time reconnect ticket; only the explicit Leave action removes state.
}

function renderRoomState({ state, message }) {
  switch (state) {
    case "connected": render(); break;
    case "waiting": showState("Waiting for approval", message || "The room is checking this invite."); break;
    case "access-word": showState("Access Word Required", message || "Enter the room Access Word.", true); break;
    case "denied": showState("Request Denied", message || "The room owner denied this browser."); break;
    case "full": showState("Room Is Full", message); break;
    case "ended": showState("Live Share Ended", message); break;
    case "left": showState("You left the room", message || "This browser is no longer connected."); break;
    case "reconnecting": showState("Reconnecting…", message); break;
    case "reconnect-failed": showState("Couldn’t Reconnect", message); break;
    case "error": showState("Connection Issue", message); break;
    default: showState("Joining Live Share…", message || "Preparing encrypted peer connections.");
  }
}

function showState(title, message, accessWord = false) {
  scheduleLayoutRender.cancel();
  elements.empty_state.hidden = false;
  elements.state_title.textContent = title;
  elements.state_message.textContent = message || "";
  elements.access_form.hidden = !accessWord;
  elements.focus_view.hidden = true;
  elements.grid_view.hidden = true;
  elements.row_view.hidden = true;
}

function render() {
  if (!session || session.closed || session.state !== "connected") return;
  scheduleLayoutRender.cancel();
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
  const selected = session.media.followParticipantID ?? "";
  const options = [new Option("Automatic", "")];
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
  const sources = media.allSources().filter((source) => source.active && media.trackForSource(source));
  document.querySelectorAll("[data-layout]").forEach((button) => button.classList.toggle("active", button.dataset.layout === media.layout));
  document.querySelectorAll("[data-scale]").forEach((button) => button.classList.toggle("active", button.dataset.scale === media.scaleMode));
  elements.empty_state.hidden = sources.length > 0;
  if (sources.length === 0) {
    elements.state_title.textContent = "Waiting for a shared window";
    elements.state_message.textContent = "Connected participants are not sharing video yet.";
  }
  elements.focus_view.hidden = media.layout !== "focus" || sources.length === 0;
  elements.grid_view.hidden = media.layout !== "grid" || sources.length === 0;
  elements.row_view.hidden = media.layout !== "row" || sources.length === 0;
  if (media.layout === "focus") renderFocus(media.selectedSource());
  if (media.layout === "grid") renderCollection(elements.grid_view, sources);
  if (media.layout === "row") renderCollection(elements.row_view, sources);
}

function renderFocus(source) {
  const track = session.media.trackForSource(source);
  setVideoTrack(elements.focus_video, track);
  applyVideoPresentation(elements.focus_video, elements.focus_view, source);
  elements.source_summary.textContent = source ? sourceLabel(source) : "Waiting for a shared window";
}

function renderCollection(container, sources) {
  const keys = new Set(sources.map((source) => source.key));
  for (const [key, card] of videoElements) {
    if (!keys.has(key)) { card.remove(); videoElements.delete(key); }
  }
  for (const source of sources) {
    let card = videoElements.get(source.key);
    if (!card) {
      card = document.createElement("button"); card.type = "button"; card.className = "media-card";
      const video = document.createElement("video"); video.autoplay = true; video.playsInline = true; video.muted = true;
      const label = document.createElement("span"); label.className = "media-label";
      card.append(video, label);
      card.addEventListener("click", () => { session.media.selectSource(source.key); session.media.setLayout("focus"); });
      videoElements.set(source.key, card);
    }
    card.querySelector(".media-label").textContent = sourceLabel(source);
    setVideoTrack(card.querySelector("video"), session.media.trackForSource(source));
    applyVideoPresentation(card.querySelector("video"), card, source);
  }
  container.replaceChildren(...sources.map((source) => videoElements.get(source.key)));
}

function applyVideoPresentation(video, viewport, source) {
  const mode = session.media.scaleMode;
  video.style.position = "absolute";
  if (!source || mode !== "native") {
    Object.assign(video.style, { left: "0px", top: "0px", width: "100%", height: "100%", maxWidth: "none", maxHeight: "none", objectFit: mode === "fill" ? "cover" : "contain" });
    return;
  }
  const bounds = viewport.getBoundingClientRect();
  const geometry = nativePanGeometry({
    sourceWidth: source.sourcePointWidth,
    sourceHeight: source.sourcePointHeight,
    viewportWidth: bounds.width,
    viewportHeight: bounds.height,
    cursor: session.media.cursorForSource(source),
  });
  if (!geometry) return;
  Object.assign(video.style, {
    left: `${geometry.left}px`, top: `${geometry.top}px`,
    width: `${geometry.width}px`, height: `${geometry.height}px`,
    maxWidth: "none", maxHeight: "none", objectFit: "fill",
  });
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
