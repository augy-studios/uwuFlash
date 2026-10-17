/* The screen while presenting and while showing shared cards, in the Android
   app (js/app-bridge.js, FlashPlugin.java), where the WebView can't do what
   a browser does:

   - Kept on. The WebView has no Screen Wake Lock, so the app keeps it on.
   - At full brightness, then back to the phone's own once it's over. A web
     page can't set the brightness at all; the app sets it for its own window
     only, so the phone's setting is never touched.
   - Full screen. The WebView's Fullscreen API leaves full screen the moment it
     is asked, which would close the presenter as it opens, so the app hides
     every bar itself instead.
   - The volume keys and Back, while presenting: down for the next card, up
     for the one before, either held for the ticker, Back to stop.
   - A flick of the wrist, while presenting with it switched on.
   - Speaking a card's words, through Android's own speech screen.

   In a browser or the PWA none of this runs: app.js and viewer.js use the
   browser's own Fullscreen and Wake Lock APIs there, as before. */

import { AppBridge } from "./app-bridge.js";

/* Whether the app can hold the screen. Waits briefly for the app to say what
   it can, as the presenter may open before it has. */
export async function appScreen() {
  if (!AppBridge.native) return false;
  await AppBridge.ready(2000);
  return AppBridge.has("screen");
}

/* What each part of the page wants of the screen: the presenter, and the
   viewer. The screen gets all of them at once, so one letting go never takes
   away what the other still wants. */
const holds = new Map();

export function holdScreen(owner, want) {
  if (want) holds.set(owner, want);
  else holds.delete(owner);
  const all = { awake: false, bright: false, immersive: false };
  for (const w of holds.values()) {
    all.awake ||= Boolean(w.awake);
    all.bright ||= Boolean(w.bright);
    all.immersive ||= Boolean(w.immersive);
  }
  AppBridge.call("Flash", "screen", all).catch(() => {});
}

/* ---- the volume keys and Back ---- */

let keyHandler = null;
let keyListener = null;

/* While a handler is set, the keys come to it as "next", "previous", "hold"
   and "back"; set null, they go back to the phone. */
export function captureKeys(handler) {
  if (!AppBridge.has("keys")) return;
  keyHandler = handler;
  keyListener ??= AppBridge.listen("Flash", "key", ({ key }) => keyHandler?.(key));
  AppBridge.call("Flash", "keys", { on: Boolean(handler) }).catch(() => {});
}

/* ---- flick ---- */

let flickHandler = null;
let flickListener = null;

export function canFlick() {
  return AppBridge.has("flick");
}

/* While a handler is set, flicks come to it as 1 (next) or -1 (before). */
export function watchFlick(handler) {
  if (!canFlick()) return;
  flickHandler = handler;
  flickListener ??= AppBridge.listen("Flash", "flick", ({ direction }) => {
    if (direction === 1 || direction === -1) flickHandler?.(direction);
  });
  AppBridge.call("Flash", "flick", { on: Boolean(handler) }).catch(() => {});
}

/* ---- speaking ---- */

export function canListen() {
  return AppBridge.has("listen");
}

/* What was said, or null if the speech screen was backed out of. */
export async function listen(prompt) {
  try {
    const { text } = await AppBridge.call("Flash", "listen", { prompt });
    return typeof text === "string" && text.trim() ? text.trim() : null;
  } catch {
    return null;
  }
}
