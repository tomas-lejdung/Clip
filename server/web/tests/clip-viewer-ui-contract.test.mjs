import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const [html, script, stylesheet] = await Promise.all([
  readFile(new URL("viewer.html", root), "utf8"),
  readFile(new URL("assets/clip-viewer.js", root), "utf8"),
  readFile(new URL("assets/clip-viewer.css", root), "utf8"),
]);

function elementWithID(tagName, identifier) {
  const match = html.match(new RegExp(`<${tagName}\\b(?=[^>]*\\bid="${identifier}")[^>]*>[\\s\\S]*?<\\/${tagName}>`, "u"));
  assert.ok(match, `expected a <${tagName}> with id="${identifier}"`);
  return match[0];
}

function visibleText(markup) {
  return markup.replace(/<[^>]+>/gu, " ").replace(/\s+/gu, " ").trim();
}

function accessibleIconButton(identifier) {
  const button = elementWithID("button", identifier);
  assert.match(button, /class="[^"]*\bicon-button\b[^"]*"/u, `${identifier} should use the compact icon-button treatment`);
  assert.match(button, /aria-label="[^"]+"/u, `${identifier} should have an accessible label`);
  assert.match(button, /data-tooltip="[^"]+"/u, `${identifier} should expose a tooltip`);
  assert.match(button, /<svg\b[^>]*aria-hidden="true"/u, `${identifier} should render an aria-hidden SVG icon`);
  return button;
}

test("viewer defaults to sharp Native Focus and exposes only Focus or Row", () => {
  assert.match(html, /data-layout="focus" class="active"/u);
  assert.match(html, /data-layout="row"/u);
  assert.doesNotMatch(html, /data-layout="grid"|id="grid-view"/u);
  assert.match(html, /data-scale="native" class="active"/u);
  assert.match(html, /value="manual">Off · Manual/u);
});

test("focus viewer contains the fixed surface, filmstrip, and Native minimap contract", () => {
  for (const identifier of [
    "focus-surface", "source-filmstrip", "native-minimap",
    "native-minimap-image", "native-minimap-viewport",
  ]) assert.match(html, new RegExp(`id="${identifier}"`, "u"));

  assert.match(script, /nativeManualPanGeometry/u);
  assert.match(script, /nativeMinimapGeometry/u);
  assert.match(script, /snapToDevicePixel/u);
  assert.match(script, /media\.nativePanForSource/u);
  assert.match(script, /media\.setNativePanForSource/u);
  assert.match(script, /new ResizeObserver\(handleViewportChange\)/u);
  assert.match(script, /"fullscreenchange"[\s\S]*scheduleMotionRender\(\)/u);
  assert.match(stylesheet, /\.focus-surface[^}]*will-change:\s*transform/su);
  assert.match(stylesheet, /\.native-minimap/u);
});

test("HUD and window navigation preserve the old interaction cues", () => {
  assert.match(script, /HUD_IDLE_MILLISECONDS\s*=\s*3_000/u);
  assert.match(script, /hasRenderableMedia\s*&&\s*!hadRenderableMedia\) revealHUD\(\)/u);
  assert.match(script, /\["pointermove", "pointerdown", "keydown"\]/u);
  assert.match(stylesheet, /\.hud-hidden \.topbar/u);
  assert.match(stylesheet, /\.hud-hidden \.controlbar/u);
  assert.match(stylesheet, /\.hud-hidden \.source-filmstrip/u);
  assert.match(stylesheet, /\.source-thumbnail\.publisher-focused/u);
  assert.match(stylesheet, /\.source-thumbnail\.viewer-selected/u);
  assert.match(stylesheet, /\.source-thumbnail video[^}]*object-fit:\s*contain/su);
  assert.match(stylesheet, /\.hud-hidden \.native-minimap\s*\{\s*bottom:\s*16px/su);
  assert.match(script, /sourceLabel\(source\)/u);
  assert.match(script, /function followRowSource/u);
  assert.match(script, /session\.media\.followEnabled/u);
  assert.match(script, /reason === "cursor"\) scheduleMotionRender\(\)/u);
  assert.doesNotMatch(script, /reason === "cursor"\) scheduleLayoutRender\(\)/u);
});

test("Web diagnostics are reachable from the top HUD, not the bottom controlbar", () => {
  for (const identifier of [
    "diagnostics-button", "diagnostics-panel", "diagnostics-copy",
    "diagnostics-list",
  ]) assert.match(html, new RegExp(`id="${identifier}"`, "u"));
  const topActions = elementWithID("div", "top-actions");
  const controlbar = elementWithID("nav", "controlbar");
  assert.match(topActions, /id="diagnostics-button"/u);
  assert.doesNotMatch(controlbar, /id="diagnostics-button"/u);
  assert.equal(visibleText(accessibleIconButton("diagnostics-button")), "");
  assert.match(script, /new ClipWebDiagnosticsSampler\(\)/u);
  assert.match(script, /!elements\.participants_panel\.hidden \|\| !elements\.diagnostics_panel\.hidden/u);
  assert.match(script, /navigator\.clipboard\.writeText\(formatWebDiagnostics\(latestDiagnostics\)\)/u);
  assert.match(stylesheet, /\.diagnostics-panel/u);
  assert.doesNotMatch(html, /id="diagnostics-summary"/u);
  assert.doesNotMatch(script, /diagnosticMetric\(/u);
  assert.match(stylesheet, /\.side-panel[^}]*overflow-x:\s*hidden/su);
  assert.match(stylesheet, /\.diagnostics-panel[^}]*bottom:\s*auto[^}]*max-height:/su);
  assert.match(stylesheet, /\.diagnostics-fact:first-child dd[^}]*overflow-wrap:\s*anywhere[^}]*white-space:\s*normal/su);
  assert.match(script, /function diagnosticAudioTrack\(track\)[\s\S]*track\.codec[\s\S]*track\.bitrateKbps/u);
  assert.match(script, /const audioTracks = peer\.tracks\.filter[\s\S]*const videoTracks = peer\.tracks\.filter/u);
  assert.match(stylesheet, /\.diagnostics-audio-track/u);
  assert.doesNotMatch(html, /Statistics come from this browser\. Values that its WebRTC implementation does not expose are shown as unavailable\./u);
});

test("compact HUD controls use icons with accessible labels and tooltips", () => {
  const participants = accessibleIconButton("participants-button");
  const fullscreen = accessibleIconButton("fullscreen-button");
  const masterMute = accessibleIconButton("master-mute");

  assert.equal(visibleText(participants), "0");
  assert.match(participants, /<span\b(?=[^>]*id="participant-count")(?=[^>]*class="[^"]*\bbadge\b[^"]*")[^>]*>0<\/span>/u);
  assert.doesNotMatch(visibleText(participants), /\bPeople\b/u);
  assert.equal(visibleText(fullscreen), "");
  assert.equal(visibleText(masterMute), "");

  assert.match(masterMute, /aria-pressed="true"/u);
  assert.match(script, /elements\.master_mute\.setAttribute\("aria-pressed",\s*String\(masterMuted\)\)/u);
  assert.match(script, /setControlIcon\(elements\.master_mute,\s*masterMuted\s*\?\s*"volume-muted"\s*:\s*"volume"\)/u);
  assert.match(script, /setControlLabel\(elements\.master_mute,\s*masterMuted\s*\?/u);
  assert.doesNotMatch(script, /elements\.master_mute\.textContent\s*=/u);

  assert.doesNotMatch(script, /elements\.fullscreen_button\.textContent\s*=/u);
  assert.match(script, /setControlIcon\(elements\.fullscreen_button,\s*fullscreen\s*\?\s*"fullscreen-exit"\s*:\s*"fullscreen"\)/u);
  assert.match(script, /setControlLabel\(elements\.fullscreen_button,\s*fullscreen\s*\?/u);
});

test("participant count updates the badge and participant control description", () => {
  assert.match(script, /elements\.participant_count\.textContent = String\(members\.length\)/u);
  assert.match(script, /syncParticipantsControl\(members\.length\)/u);
  assert.match(script, /function syncParticipantsControl\(count[\s\S]*setControlLabel\(elements\.participants_button,[\s\S]*summary\)/u);
});

test("the master mute control is the single browser audio-unlock entry point", () => {
  assert.doesNotMatch(html, /id="audio-unlock"|>Enable Audio<\/button>/u);
  assert.match(script, /elements\.master_mute\.addEventListener\("click", toggleMasterAudio\)/u);
  assert.match(script, /function toggleMasterAudio\(\)[\s\S]*audioUnlocked = true;[\s\S]*masterMuted = false;[\s\S]*syncAudio\(\)/u);
  assert.match(script, /audio\.play\(\)\.catch\(\(\) => \{[\s\S]*audioUnlocked = false;[\s\S]*masterMuted = true;/u);
  assert.match(elementWithID("button", "leave-button"), />Leave<\/button>$/u);
});

test("the bottom HUD does not repeat the selected source next to Follow", () => {
  const controlbar = elementWithID("nav", "controlbar");
  assert.doesNotMatch(controlbar, /id="source-summary"|class="source-summary"/u);
  assert.doesNotMatch(script, /source_summary/u);
  assert.doesNotMatch(stylesheet, /\.source-summary/u);
  assert.match(stylesheet, /\.controlbar[^}]*width:\s*fit-content/su);
});

test("top-left HUD is a compact accessible room status without redundant branding", () => {
  const topbar = html.match(/<header class="topbar hud">[\s\S]*?<\/header>/u)?.[0] ?? "";
  assert.match(topbar, /id="room-heading"[^>]*data-state="joining"[^>]*aria-labelledby="room-status room-label"/u);
  assert.match(topbar, /class="room-status-chip">\s*<span class="room-status-dot"/u);
  assert.match(topbar, /id="room-status" role="status" aria-live="polite">Joining<\/span>/u);
  assert.match(topbar, /id="room-label" class="room-code" aria-label="Room code">…<\/strong>/u);
  assert.doesNotMatch(topbar, /Clip Live Share|Secure room|· WEB|brand-mark|room-heading-copy/u);
  assert.match(script, /elements\.room_label\.textContent = session\.invite\.roomCode/u);
  assert.doesNotMatch(script, /elements\.room_label\.textContent = `Room /u);
  assert.match(script, /case "connected": setHeaderStatus\("Connected", "connected"\)/u);
  assert.match(stylesheet, /\.room-status-chip, \.room-code[^}]*display:\s*flex/su);
  assert.match(stylesheet, /\.room-heading\[data-state="connected"\] \.room-status-dot/u);
  assert.match(stylesheet, /\.hud-hidden \.topbar/u);
});

test("leaving the room replaces dead viewer controls with terminal actions", () => {
  assert.match(html, /id="top-actions" class="top-actions"/u);
  assert.match(html, /id="controlbar" class="controlbar hud"/u);
  assert.match(html, /id="terminal-actions" class="terminal-actions" hidden/u);
  assert.match(html, /id="rejoin-button"[^>]*>Join Again<\/button>/u);
  assert.doesNotMatch(html, /id="close-tab-button"/u);
  assert.match(script, /setTerminalUI\(state === "left" \|\| state === "ended"\)/u);
  assert.match(script, /elements\.top_actions\.hidden = isTerminal/u);
  assert.match(script, /elements\.controlbar\.hidden = isTerminal/u);
  assert.match(script, /elements\.rejoin_button\.addEventListener\("click", \(\) => window\.location\.reload\(\)\)/u);
});
