import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const [html, script, stylesheet] = await Promise.all([
  readFile(new URL("viewer.html", root), "utf8"),
  readFile(new URL("assets/clip-viewer.js", root), "utf8"),
  readFile(new URL("assets/clip-viewer.css", root), "utf8"),
]);

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
