/* The other screen: the guest's side of sharing. See STUN-p2p-spec.md at the
   repo root, and share.js for the host's side.

   A full screen overlay over the editor. It joins a host by code, then waits
   on a plain screen until the host presses play; from then on it shows
   whatever card the host is presenting, in the host's colours, and goes back
   to waiting when the host stops. It never touches this device's own deck
   or its saved theme: pictures are held in memory only, and the colours go
   back to this device's own when it leaves.

   Everything that arrives is input from another device, so it is checked
   field by field before it is used, and nothing received goes near
   innerHTML except through the card renderer, which escapes text. */

import { Guest, normaliseCode, isValidCode } from "./p2p.js";
import { renderCard } from "./render.js";
import { LAYOUTS, DEFAULT_LAYOUT, TEXT_SIZES } from "./deck.js";
import { COLOR_THEMES, initTheme, showColorTheme } from "./theme.js";
import { readSetting, writeSetting } from "./store.js";

// Measured in time, not missed snapshots: at twenty a second, three missed
// is shorter than an ordinary wifi stall.
const STALE_MS = 2000;
const BEAT_MS = 500;
// A card whose picture has not arrived yet is held back this long, so it
// does not paint its words first and the picture a moment later.
const IMAGE_WAIT_MS = 4000;
const RETRY_FIRST_MS = 2000;
const RETRY_MAX_MS = 30000;

const MAX_IMAGES = 40;
const MAX_INCOMING = 4;
const MAX_CHUNKS = 1000;
const MAX_CHUNK_CHARS = 16000;
const MAX_LAYERS = 40;
const MAX_TEXT = 2000;
const IMAGE_ID = /^img-[a-z0-9-]{1,40}$/;
const IMAGE_TYPES = new Set([
  "image/png", "image/jpeg", "image/webp", "image/gif", "image/avif", "image/bmp", "image/svg+xml",
]);

const COPY = {
  unreachable:
    "Could not reach the other device. Both have to be on the same network: join the same wifi, or turn on a hotspot on one and join it from the other. Check the code is still the one on screen.",
  load: "Could not load sharing. Check your connection.",
};

const el = {};
let open = false;
let guest = null;
let code = "";
let status = "idle";
let failure = "";
let ended = false;
let outdated = false;

// After a connection that was working drops, keep trying quietly rather
// than showing a failure: the usual cause is the host's phone locking, and
// it comes back.
let resuming = false;
let retryTimer = null;
let retryDelay = RETRY_FIRST_MS;

let state = null;
let lastStateAt = 0;
let beatTimer = null;
let wakeLock = null;

const images = new Map(); // image id -> object URL, oldest first
const incoming = new Map(); // image id -> { mime, total, parts, count }
let shownKey = "";
let waitKey = "";
let waitSince = 0;

/* ---- joining ---- */

export function startViewing(input) {
  const next = normaliseCode(input);
  if (!isValidCode(next)) return false;

  code = next;
  writeSetting("lastCode", code);
  writeSetting("shareRole", "guest");

  ended = false;
  outdated = false;
  resuming = false;
  retryDelay = RETRY_FIRST_MS;
  state = null;
  showNothing();
  openViewer();
  join();
  return true;
}

async function join() {
  clearTimeout(retryTimer);
  retryTimer = null;

  const old = guest;
  guest = null;
  old?.close();

  const g = new Guest();
  guest = g;
  status = "connecting";
  failure = "";
  renderPanel();

  g.addEventListener("status", ({ detail }) => {
    if (guest === g) onStatus(detail);
  });
  g.addEventListener("message", ({ detail: { message } }) => {
    if (guest === g) onMessage(message);
  });

  try {
    await g.connect(code);
  } catch {
    if (guest !== g) return;
    guest = null;
    onStatus({ status: "error", message: COPY.load });
  }
}

function onStatus(detail) {
  switch (detail.status) {
    case "connecting":
      status = "connecting";
      break;
    case "connected":
      status = "connected";
      resuming = false;
      retryDelay = RETRY_FIRST_MS;
      lastStateAt = Date.now();
      // Pictures kept from before a reconnect are still good.
      sendHave();
      break;
    case "dropped":
      status = "dropped";
      resuming = true;
      scheduleRetry();
      break;
    case "unreachable":
      status = "unreachable";
      if (resuming) scheduleRetry();
      break;
    case "error":
      status = "error";
      failure = detail.message || "The connection failed.";
      if (resuming) scheduleRetry();
      break;
    default:
      return;
  }
  renderPanel();
}

function scheduleRetry() {
  if (!open) return;
  clearTimeout(retryTimer);
  retryTimer = setTimeout(join, retryDelay);
  retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
}

function hangUp() {
  const g = guest;
  guest = null;
  g?.close();
  status = "idle";
}

function onMessage(message) {
  switch (message.type) {
    case "state":
      state = readState(message);
      lastStateAt = Date.now();
      wearTheme(state.theme);
      apply();
      break;
    case "image":
      receiveImage(message);
      break;
    case "end":
      // The host stopped on purpose. Its code is gone, so there is nothing
      // to come back to.
      ended = true;
      state = null;
      clearTimeout(retryTimer);
      resuming = false;
      hangUp();
      apply();
      break;
    case "outdated":
      outdated = true;
      hangUp();
      break;
    default:
      // Anything from a newer build. Never thrown on.
      return;
  }
  renderPanel();
}

function sendHave() {
  guest?.send({ type: "have", images: [...images.keys()] });
}

/* ---- checking what arrives ---- */

function readState(message) {
  const theme = {
    color: COLOR_THEMES.some((t) => t.id === message.theme?.color) ? message.theme.color : COLOR_THEMES[0].id,
    mode: message.theme?.mode === "dark" ? "dark" : "light",
  };
  const card = message.presenting === true ? readCard(message.card) : null;
  return { presenting: card !== null, card, theme };
}

// Layer ids are made here, by position, rather than taken from the wire.
function readCard(card) {
  if (!card || typeof card !== "object" || !Array.isArray(card.layers)) return null;

  const layers = card.layers
    .slice(0, MAX_LAYERS)
    .map((layer, i) => {
      if (layer?.type === "image") {
        if (typeof layer.imageId !== "string" || !IMAGE_ID.test(layer.imageId)) return null;
        return {
          id: `l${i}`,
          type: "image",
          imageId: layer.imageId,
          fit: layer.fit === "cover" ? "cover" : "contain",
          hidden: false,
        };
      }
      if (layer?.type === "text") {
        return {
          id: `l${i}`,
          type: "text",
          text: typeof layer.text === "string" ? layer.text.slice(0, MAX_TEXT) : "",
          size: TEXT_SIZES.some((s) => s.id === layer.size) ? layer.size : "l",
          align: ["left", "center", "right"].includes(layer.align) ? layer.align : "center",
          hidden: false,
        };
      }
      return null;
    })
    .filter(Boolean);

  return {
    layout: LAYOUTS.some((l) => l.id === card.layout) ? card.layout : DEFAULT_LAYOUT,
    layers,
  };
}

function receiveImage(m) {
  if (
    typeof m.id !== "string" || !IMAGE_ID.test(m.id) ||
    !IMAGE_TYPES.has(m.mime) ||
    !Number.isInteger(m.total) || m.total < 1 || m.total > MAX_CHUNKS ||
    !Number.isInteger(m.seq) || m.seq < 0 || m.seq >= m.total ||
    typeof m.data !== "string" || m.data.length > MAX_CHUNK_CHARS
  ) {
    return;
  }
  if (images.has(m.id)) return;

  let entry = incoming.get(m.id);
  if (!entry || entry.total !== m.total || entry.mime !== m.mime) {
    entry = { mime: m.mime, total: m.total, parts: new Array(m.total), count: 0 };
    incoming.set(m.id, entry);
    // Bounded, so a host that starts transfers and never finishes them
    // cannot fill this device's memory.
    while (incoming.size > MAX_INCOMING) incoming.delete(incoming.keys().next().value);
  }

  if (entry.parts[m.seq] === undefined) {
    entry.parts[m.seq] = m.data;
    entry.count++;
  }
  if (entry.count < entry.total) return;

  incoming.delete(m.id);
  let url;
  try {
    const binary = atob(entry.parts.join(""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    url = URL.createObjectURL(new Blob([bytes], { type: entry.mime }));
  } catch {
    return;
  }

  images.set(m.id, url);
  evictImages();
  sendHave();
  apply();
}

// Oldest first. The card on screen was touched when it was drawn, so its
// own pictures are the newest and are never the ones to go.
function evictImages() {
  while (images.size > MAX_IMAGES) {
    const [id, url] = images.entries().next().value;
    URL.revokeObjectURL(url);
    images.delete(id);
  }
}

function touchImages(card) {
  card.layers.forEach((layer) => {
    if (layer.type !== "image" || !images.has(layer.imageId)) return;
    const url = images.get(layer.imageId);
    images.delete(layer.imageId);
    images.set(layer.imageId, url);
  });
}

/* ---- drawing ---- */

function wearTheme({ color, mode }) {
  const root = document.documentElement;
  if (root.getAttribute("data-color-theme") !== color) showColorTheme(color);
  if (root.getAttribute("data-mode") !== mode) root.setAttribute("data-mode", mode);
}

function apply() {
  const card = state?.presenting ? state.card : null;
  if (!card) {
    if (shownKey) showNothing();
    return;
  }

  const cardKey = JSON.stringify(card);
  const imageLayers = card.layers.filter((l) => l.type === "image");
  const ready = imageLayers.filter((l) => images.has(l.imageId)).length;

  // The pictures that have arrived are part of the key, so one landing
  // after the wait ran out redraws the card with it.
  const key = `${cardKey}|${ready}`;
  if (key === shownKey) return;

  if (ready < imageLayers.length) {
    if (waitKey !== cardKey) {
      waitKey = cardKey;
      waitSince = Date.now();
    }
    if (Date.now() - waitSince < IMAGE_WAIT_MS) return;
  }

  shownKey = key;
  touchImages(card);
  renderCard(card, el.canvas, {
    presenting: true,
    resolveImage: (id) => images.get(id) ?? null,
  });
  el.viewer.classList.add("showing");
}

function showNothing() {
  shownKey = "";
  if (!el.canvas) return;
  el.canvas.innerHTML = "";
  el.viewer.classList.remove("showing");
}

function setText(node, text) {
  if (node.textContent !== text) node.textContent = text;
}

function renderPanel() {
  if (!open) return;

  const stale = status === "connected" && Date.now() - lastStateAt > STALE_MS;
  const readable = `${code.slice(0, 3)} ${code.slice(3)}`;
  let title;
  let message;
  let actions = ["leave"];
  let badge = "";

  if (ended) {
    title = "Sharing ended";
    message = "The other device stopped sharing.";
  } else if (outdated) {
    title = "Different versions";
    message = "These two devices are running different versions of uwuFlash. Reload the page on both.";
  } else if (resuming) {
    title = "Reconnecting";
    message = "Lost the connection to the other device. Trying again...";
    badge = "Reconnecting...";
  } else if (status === "unreachable") {
    title = "Could not connect";
    message = COPY.unreachable;
    actions = ["retry", "leave"];
  } else if (status === "error") {
    title = "Could not connect";
    message = failure;
    actions = ["retry", "leave"];
  } else if (status === "connected") {
    title = "Ready";
    message = stale
      ? "Not hearing from the other device. It may be asleep or out of range."
      : `Joined ${readable}. The cards appear here when the other device presses play.`;
    actions = ["fullscreen", "leave"];
    if (stale) badge = "Connection looks stale";
  } else {
    title = "Connecting";
    message = `Joining ${readable}...`;
  }

  setText(el.title, title);
  setText(el.message, message);
  el.retry.hidden = !actions.includes("retry");
  el.fullscreen.hidden = !actions.includes("fullscreen") || !document.fullscreenEnabled || !!document.fullscreenElement;
  el.leave.textContent = ended || outdated ? "Back to my cards" : "Leave";

  // The badge only matters over a card; with no card, the panel says it.
  const showBadge = badge !== "" && shownKey !== "";
  el.badge.hidden = !showBadge;
  setText(el.badge, showBadge ? badge : "");
}

/* ---- the overlay ---- */

function openViewer() {
  if (open) return;
  open = true;
  el.viewer.classList.remove("hidden");
  document.body.classList.add("viewing");
  beatTimer = setInterval(beat, BEAT_MS);
  requestWakeLock();
}

// Twice a second: the ping the host uses to notice a screen that has gone,
// the staleness check, and the image wait running out.
function beat() {
  guest?.send({ type: "ping" });
  apply();
  renderPanel();
}

export function leaveViewer() {
  clearTimeout(retryTimer);
  retryTimer = null;
  resuming = false;

  const g = guest;
  guest = null;
  if (g?.status === "connected") g.leave();
  else g?.close();

  writeSetting("shareRole", null);
  writeSetting("lastCode", null);

  clearInterval(beatTimer);
  beatTimer = null;
  images.forEach((url) => URL.revokeObjectURL(url));
  images.clear();
  incoming.clear();
  state = null;
  status = "idle";
  ended = false;
  outdated = false;
  showNothing();

  open = false;
  el.viewer.classList.add("hidden");
  document.body.classList.remove("viewing");
  releaseWakeLock();
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});

  // Back to this device's own colours, which were never overwritten.
  initTheme();
}

async function toggleFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen?.();
  } catch {
    /* refused, as on iOS Safari outside an installed app; the overlay still fills the page */
  }
  renderPanel();
}

async function requestWakeLock() {
  if (!open || wakeLock) return;
  try {
    wakeLock = (await navigator.wakeLock?.request("screen")) ?? null;
    wakeLock?.addEventListener("release", () => {
      wakeLock = null;
    });
  } catch {
    /* unsupported or refused; the screen may dim */
  }
}

function releaseWakeLock() {
  const lock = wakeLock;
  wakeLock = null;
  lock?.release().catch(() => {});
}

export function initViewer() {
  el.viewer = document.getElementById("viewer");
  el.canvas = document.getElementById("viewerCanvas");
  el.title = document.getElementById("viewerTitle");
  el.message = document.getElementById("viewerMessage");
  el.badge = document.getElementById("viewerBadge");
  el.retry = document.getElementById("viewerRetry");
  el.fullscreen = document.getElementById("viewerFullscreen");
  el.leave = document.getElementById("viewerLeave");

  el.retry.addEventListener("click", () => {
    retryDelay = RETRY_FIRST_MS;
    join();
  });
  el.fullscreen.addEventListener("click", toggleFullscreen);
  el.leave.addEventListener("click", leaveViewer);
  document.getElementById("viewerFullscreenCorner").addEventListener("click", toggleFullscreen);
  document.getElementById("viewerExit").addEventListener("click", leaveViewer);
  document.addEventListener("fullscreenchange", renderPanel);

  // The browser drops a wake lock when the page is hidden, and a channel
  // often dies with a backgrounded page. Both come back here.
  document.addEventListener("visibilitychange", () => {
    if (!open || document.visibilityState !== "visible") return;
    requestWakeLock();
    if (resuming && retryTimer !== null) join();
  });

  // The QR code's link, or the screen this device was last showing. The
  // code is taken out of the address bar once read, so a reload comes back
  // through the remembered code instead, and a leave is not undone by one.
  const params = new URLSearchParams(location.search);
  const linked = params.get("join");
  if (linked !== null) {
    params.delete("join");
    const query = params.toString();
    history.replaceState(null, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
  }

  const remembered = readSetting("shareRole") === "guest" ? readSetting("lastCode") : null;
  const initial = isValidCode(linked) ? linked : remembered;
  if (isValidCode(initial)) startViewing(initial);
}
