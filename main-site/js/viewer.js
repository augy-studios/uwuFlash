/* The other screen: the guest's side of sharing. See STUN-p2p-spec.md at the
   repo root, and share.js for the host's side.

   A full screen overlay over the editor. It joins a host by code, then waits
   on a plain screen until the host presses play; from then on it shows
   whatever card the host is presenting, in the host's colours, and goes back
   to waiting when the host stops. It never touches this device's own deck
   or its saved theme: pictures are held in memory only, and the colours go
   back to this device's own when it leaves.

   On a Big Screen this is one of several screens showing one card. The host
   says where it sits in the grid, and it draws the whole card at the size of
   the whole grid with only its own piece inside the screen. Asked to, it
   shows its number over everything, so the screens can be put in order, or
   lines across the whole wall, so the bezels between them can be set.

   With the card's ticker on, its words roll along one line instead,
   timed by the host's clock so that every screen of a Big Screen has the
   line in the same place and it runs straight on from one to the next.

   The one exception is a host that picked Send. Then nothing is shown, and
   the host's whole deck arrives instead, pictures and all, with a choice to
   add it to this device's cards or replace them. Even then the deck is only
   held here until one of those is pressed; app.js does the writing.

   Everything that arrives is input from another device, so it is checked
   field by field before it is used, and nothing received goes near
   innerHTML except through the card renderer, which escapes text. */

import { Guest, normaliseCode, isValidCode, MAX_SHARED_IMAGES, MAX_SCREENS } from "./p2p.js";
import { renderCard } from "./render.js";
import { renderTicker, hasTickerText, TICKER_SPEEDS } from "./ticker.js";
import { LAYOUTS, DEFAULT_LAYOUT, TEXT_SIZES, readFocus, readTickerSpeed } from "./deck.js";
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
// A window being dragged to a new size says so many times a second; the
// host only needs where it ends up.
const RESIZE_MS = 250;
// A Big Screen screen moving to a new place; the same time as the tiles in
// the host's grid, in share.js.
const SWAP_MS = 420;
// A screen this close to the card's shape fills itself with the card,
// cropping a sliver, rather than showing thin bars down two sides.
const SHAPE_SLACK = 0.12;
// The host's clock is read off each snapshot. The one that took least time
// to arrive is the truest, so the best of the last few seconds is kept.
const CLOCK_WINDOW_MS = 5000;

const MAX_IMAGES = 40;
const MAX_INCOMING = 4;
const MAX_CHUNKS = 1000;
const MAX_CHUNK_CHARS = 16000;
const MAX_LAYERS = 40;
const MAX_TEXT = 2000;
const MAX_DECK_CARDS = 500;
// Replace throws away this device's own cards, so it takes a second tap
// within this long.
const ARM_MS = 4000;
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
let removed = false;
let outdated = false;
let full = false;
let screenId = "";
let resizeTimer = null;
let wallKey = "";

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

// Host clock minus this one's, from snapshots: [{ at, offset }], newest last.
let clockSamples = [];

// A deck the host is sending: { cards, imageIds, blobs: id -> Blob,
// missing: ids the host could not read }. Its pictures are kept apart from
// `images`, which evicts, so a deck with many pictures arrives whole.
let offer = null;
let copying = false;
let replaceArmed = false;
let armTimer = null;
let onImport = async () => {};

/* ---- joining ---- */

export function startViewing(input) {
  const next = normaliseCode(input);
  if (!isValidCode(next)) return false;

  code = next;
  writeSetting("lastCode", code);
  writeSetting("shareRole", "guest");

  ended = false;
  removed = false;
  outdated = false;
  resuming = false;
  retryDelay = RETRY_FIRST_MS;
  state = null;
  clockSamples = [];
  showNothing();
  openViewer();
  join();
  return true;
}

/* What this screen calls itself to the host, so a Big Screen puts it back in
   the same place after a dropped connection or a reload. Kept for the tab,
   not the device: two tabs side by side are two screens. */
function ownScreenId() {
  if (screenId) return screenId;
  try {
    screenId = sessionStorage.getItem("uwuFlash.screenId") || "";
  } catch {
    /* storage refused; made fresh below and kept for this page */
  }
  if (!/^[a-z0-9]{6,24}$/.test(screenId)) {
    screenId = [...crypto.getRandomValues(new Uint8Array(12))].map((b) => (b % 36).toString(36)).join("");
    try {
      sessionStorage.setItem("uwuFlash.screenId", screenId);
    } catch {
      /* as above */
    }
  }
  return screenId;
}

/* This screen's size, and a guess at how many CSS pixels make a millimetre
   on it, so a Big Screen of different screens can line them up by how big
   they really are. A page cannot ask, so it goes by the kind of device:
   phones draw about 160 to the inch, tablets about 132, computers about 110.
   Two of the same model always agree, which is the usual Big Screen. */
function screenSize() {
  const short = Math.min(window.screen?.width || 0, window.screen?.height || 0) || Math.min(window.innerWidth, window.innerHeight);
  const coarse = window.matchMedia?.("(pointer: coarse)").matches ?? false;
  const perInch = coarse ? (short < 600 ? 160 : 132) : 110;
  return { w: window.innerWidth, h: window.innerHeight, ppm: Math.round((perInch / 25.4) * 1000) / 1000 };
}

function introduce() {
  return { screen: ownScreenId(), ...screenSize() };
}

async function join() {
  clearTimeout(retryTimer);
  retryTimer = null;

  const old = guest;
  guest = null;
  old?.close();

  const g = new Guest({ introduce });
  guest = g;
  status = "connecting";
  failure = "";
  full = false;
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
    case "state": {
      const next = readState(message);
      const move = placeMove(state?.wall, next.wall);
      // Taken before anything changes: what is on show at the old place.
      const leaving = move ? frontLayer() : null;
      const ghost = leaving ? ghostOf(leaving) : null;

      state = next;
      lastStateAt = Date.now();
      if (Number.isFinite(message.clock)) noteClock(message.clock);
      // The host went back to showing cards. Its deck is no longer on offer.
      if (state.mode !== "send" && offer) dropOffer();
      wearTheme(state.theme);
      apply();
      renderPanel();
      if (ghost) slideAcross(leaving, ghost, frontLayer(), move);
      return;
    }
    case "deck":
      offer = readOffer(message, offer);
      disarmReplace();
      // A fresh copy may want pictures the last one did not.
      sendHave();
      break;
    case "image":
      receiveImage(message);
      break;
    case "noimage":
      if (typeof message.id === "string" && offer?.imageIds.has(message.id)) offer.missing.add(message.id);
      break;
    case "removed":
    case "end":
      // The host stopped on purpose, or let this screen go. Either way there
      // is nothing to come back to.
      ended = true;
      removed = message.type === "removed";
      state = null;
      dropOffer();
      clearTimeout(retryTimer);
      resuming = false;
      hangUp();
      apply();
      break;
    case "outdated":
      outdated = true;
      hangUp();
      break;
    case "full":
      hangUp();
      // Coming back from a drop, the place held by this screen's old
      // connection frees up when the host notices it went quiet.
      if (resuming) scheduleRetry();
      else full = true;
      break;
    default:
      // Anything from a newer build. Never thrown on.
      return;
  }
  renderPanel();
}

// While a deck is on offer, the pictures it needs are the only ones that
// count; the host is not showing anything.
function sendHave() {
  const held = offer ? offer.blobs.keys() : images.keys();
  guest?.send({ type: "have", images: [...held] });
}

function dropOffer() {
  offer = null;
  disarmReplace();
}

/* ---- checking what arrives ---- */

function readState(message) {
  const theme = {
    color: COLOR_THEMES.some((t) => t.id === message.theme?.color) ? message.theme.color : COLOR_THEMES[0].id,
    mode: message.theme?.mode === "dark" ? "dark" : "light",
  };
  const mode = message.mode === "send" ? "send" : "show";
  const card = mode === "show" && message.presenting === true ? readCard(message.card) : null;
  const wall = mode === "show" ? readWall(message.wall) : null;
  const shape = Number.isFinite(message.shape) ? Math.min(Math.max(message.shape, 0.25), 4) : null;
  const ticker =
    card && message.ticker && Object.hasOwn(TICKER_SPEEDS, message.ticker.speed) ? { speed: message.ticker.speed } : null;
  return { mode, presenting: card !== null, card, theme, wall, shape, ticker };
}

/* Where this screen sits in a Big Screen, or null for the whole card. Every
   number has to agree with the others, or the screen draws the whole card
   rather than some other screen's piece. */
function readWall(wall) {
  if (!wall || typeof wall !== "object") return null;
  const within = (n, min, max) => Number.isInteger(n) && n >= min && n <= max;
  const { n, of, col, row, cols, rows } = wall;
  if (
    !within(cols, 1, MAX_SCREENS) || !within(rows, 1, MAX_SCREENS) || cols * rows > MAX_SCREENS * 2 ||
    !within(col, 0, cols - 1) || !within(row, 0, rows - 1) ||
    !within(of, 1, MAX_SCREENS) || !within(n, 1, of)
  ) {
    return null;
  }
  return {
    n, of, col, row, cols, rows,
    identify: wall.identify === true,
    lines: wall.lines === true,
    box: readBox(wall.box, wall),
  };
}

// The whole wall measured in this screen. Without one, from a host before
// screens had sizes, every screen takes an equal share.
function readBox(box, { col, row, cols, rows }) {
  const fine = (n, min, max) => Number.isFinite(n) && n >= min && n <= max;
  if (box && fine(box.w, 1, 100) && fine(box.h, 1, 100) && fine(box.x, -100, 0) && fine(box.y, -100, 0)) {
    return { x: box.x, y: box.y, w: box.w, h: box.h };
  }
  return { x: -col, y: -row, w: cols, h: rows };
}

/* A sent deck. Cards that do not read are dropped, and so are image layers
   past the picture limit, so what is offered is exactly what can arrive.
   Pictures already received for an earlier copy are kept. */
function readOffer(message, previous) {
  if (!Array.isArray(message.cards)) return null;

  const imageIds = new Set();
  const cards = message.cards
    .slice(0, MAX_DECK_CARDS)
    .map(readCard)
    .filter(Boolean)
    .map((card) => ({
      ...card,
      layers: card.layers.filter((layer) => {
        if (layer.type !== "image" || imageIds.has(layer.imageId)) return true;
        if (imageIds.size >= MAX_SHARED_IMAGES) return false;
        imageIds.add(layer.imageId);
        return true;
      }),
    }));
  if (cards.length === 0) return null;

  const keep = ([id]) => imageIds.has(id);
  return {
    cards,
    imageIds,
    blobs: new Map([...(previous?.blobs ?? [])].filter(keep)),
    missing: new Set([...(previous?.missing ?? [])].filter((id) => imageIds.has(id))),
  };
}

function picturesPending() {
  return offer ? offer.imageIds.size - offer.blobs.size - offer.missing.size : 0;
}

// Layer ids are made here, by position, rather than taken from the wire.
// A shown card never carries hidden layers; a sent deck flags them.
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
          fill: layer.fill === true,
          focus: readFocus(layer.focus),
          hidden: layer.hidden === true,
        };
      }
      if (layer?.type === "text") {
        return {
          id: `l${i}`,
          type: "text",
          text: typeof layer.text === "string" ? layer.text.slice(0, MAX_TEXT) : "",
          size: TEXT_SIZES.some((s) => s.id === layer.size) ? layer.size : "l",
          align: ["left", "center", "right"].includes(layer.align) ? layer.align : "center",
          hidden: layer.hidden === true,
        };
      }
      return null;
    })
    .filter(Boolean);

  return {
    layout: LAYOUTS.some((l) => l.id === card.layout) ? card.layout : DEFAULT_LAYOUT,
    layers,
    ticker: card.ticker === true,
    tickerSpeed: readTickerSpeed(card.tickerSpeed),
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
  if (offer?.imageIds.has(m.id) ? offer.blobs.has(m.id) : images.has(m.id)) return;

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
  let blob;
  try {
    const binary = atob(entry.parts.join(""));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    blob = new Blob([bytes], { type: entry.mime });
  } catch {
    return;
  }

  // Asked again here, not at the first chunk: the deck may have been sent
  // afresh while this picture was on its way.
  if (offer?.imageIds.has(m.id)) {
    offer.blobs.set(m.id, blob);
    offer.missing.delete(m.id);
    sendHave();
    return;
  }

  images.set(m.id, URL.createObjectURL(blob));
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

/* ---- the host's clock ---- */

function noteClock(hostClock) {
  const at = Date.now();
  clockSamples.push({ at, offset: hostClock - at });
  while (clockSamples.length > 1 && at - clockSamples[0].at > CLOCK_WINDOW_MS) clockSamples.shift();
}

// Now, by the host's clock. A snapshot is late by however long it took to
// arrive, so the largest offset seen lately is the closest to the truth.
function hostNow() {
  const offset = clockSamples.reduce((best, s) => Math.max(best, s.offset), -Infinity);
  return Date.now() + (Number.isFinite(offset) ? offset : 0);
}

/* ---- drawing ---- */

function wearTheme({ color, mode }) {
  const root = document.documentElement;
  if (root.getAttribute("data-color-theme") !== color) showColorTheme(color);
  if (root.getAttribute("data-mode") !== mode) root.setAttribute("data-mode", mode);
}

/* Where the card is drawn, as fractions of this screen.

   On a Big Screen the card is drawn the size of the whole wall and moved so
   this screen's piece is the part inside it. The host works out the wall
   from how big every screen really is and how much hides behind the bezels
   between them, so a line crossing two screens stays straight. Sizes on the
   card are relative to the box it is drawn in, so the words come out one
   size across every screen.

   Otherwise the card keeps the shape it has on the other device, as large
   as fits inside the part of this screen clear of notches and rounded
   corners, with the card's colour round it. A picture is then cropped the
   same here as there, instead of a wide card being cut down to a tall
   phone's shape and looking zoomed in. */
function stageRect() {
  if (state?.wall) return state.wall.box;

  const W = el.viewer.clientWidth || window.innerWidth;
  const H = el.viewer.clientHeight || window.innerHeight;
  const inset = safeInsets();
  const room = { x: inset.left, y: inset.top, w: Math.max(1, W - inset.left - inset.right), h: Math.max(1, H - inset.top - inset.bottom) };
  const shape = state?.shape;
  let { w, h } = room;
  if (shape && Math.abs(Math.log((room.w / room.h) / shape)) > Math.log(1 + SHAPE_SLACK)) {
    if (room.w / room.h > shape) w = room.h * shape;
    else h = room.w / shape;
  }
  return {
    x: (room.x + (room.w - w) / 2) / W,
    y: (room.y + (room.h - h) / 2) / H,
    w: w / W,
    h: h / H,
  };
}

// The notch, the camera, rounded corners and the home bar, as the browser
// reports them. Nothing on a screen without any.
function safeInsets() {
  const probe = el.safe;
  if (!probe) return { top: 0, right: 0, bottom: 0, left: 0 };
  const cs = getComputedStyle(probe);
  const px = (v) => Number.parseFloat(v) || 0;
  return { top: px(cs.paddingTop), right: px(cs.paddingRight), bottom: px(cs.paddingBottom), left: px(cs.paddingLeft) };
}

function placeStage() {
  const { x, y, w, h } = stageRect();
  const key = [x, y, w, h].map((n) => n.toFixed(5)).join(",");
  if (key === wallKey) return;
  wallKey = key;
  const style = el.wall.style;
  style.setProperty("--x", x);
  style.setProperty("--y", y);
  style.setProperty("--w", w);
  style.setProperty("--h", h);
}

function apply() {
  placeStage();
  el.viewer.classList.toggle("lining", !!(state?.wall?.lines && status === "connected" && !ended));
  // Words sized for the whole wall's width; see .on-wall in style.css.
  el.viewer.classList.toggle("on-wall", !!state?.wall);
  const card = state?.presenting ? state.card : null;
  if (!card) {
    if (shownKey) showNothing();
    return;
  }

  const ticker = state.ticker && hasTickerText(card) ? state.ticker : null;
  const cardKey = JSON.stringify([card, ticker]);
  // A ticker only draws a picture that fills the card.
  const imageLayers = card.layers.filter((l) => l.type === "image" && (!ticker || l.fill));
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
  const resolveImage = (id) => images.get(id) ?? null;
  if (ticker) renderTicker(card, el.canvas, { resolveImage, now: hostNow, speed: ticker.speed });
  else renderCard(card, el.canvas, { presenting: true, resolveImage });
  el.viewer.classList.add("showing");
}

/* ---- moving place ----

   When the host swaps this screen with another, what is on it slides off
   towards the other screen's place in the grid and the new picture follows
   in behind, all one way. The other screen does the same towards this one,
   so between them the two are seen to trade. */

// Which way this screen's place moved in the same grid, as -1, 0 or 1 across
// and down, or null. A grid of a new shape moves every screen at once, which
// is not a swap.
function placeMove(before, after) {
  if (!before || !after || before.cols !== after.cols || before.rows !== after.rows) return null;
  const dx = Math.sign(after.col - before.col);
  const dy = Math.sign(after.row - before.row);
  return dx || dy ? { dx, dy } : null;
}

// What is on show: the number, else the card, else the words saying what
// is going on.
function frontLayer() {
  if (!el.number.hidden) return el.number;
  if (el.viewer.classList.contains("showing") || el.viewer.classList.contains("lining")) return el.wall;
  return el.panel;
}

// A still copy of what is leaving, which goes while the real one comes back
// in showing the new place. Ids are left on: it is only there for the slide,
// it sits after the real one so lookups find that first, and the card's own
// styles need them.
function ghostOf(layer) {
  const ghost = layer.cloneNode(true);
  ghost.removeAttribute("role");
  ghost.setAttribute("aria-hidden", "true");
  ghost.style.pointerEvents = "none";
  return ghost;
}

function slideAcross(leaving, ghost, arriving, { dx, dy }) {
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  const x = dx * el.viewer.clientWidth;
  const y = dy * el.viewer.clientHeight;
  const timing = { duration: SWAP_MS, easing: "cubic-bezier(0.65, 0, 0.35, 1)" };

  leaving.after(ghost);
  const out = ghost.animate([{ transform: "none" }, { transform: `translate(${x}px, ${y}px)` }], timing);
  out.onfinish = out.oncancel = () => ghost.remove();
  arriving.animate([{ transform: `translate(${-x}px, ${-y}px)` }, { transform: "none" }], timing);
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
    title = removed ? "Removed" : "Sharing ended";
    message = removed ? "The other device removed this screen." : "The other device stopped sharing.";
  } else if (outdated) {
    title = "Different versions";
    message = "These two devices are running different versions of uwuFlash. Reload the page on both.";
  } else if (full) {
    title = "No room";
    message = `The other device already has as many screens as it takes, ${MAX_SCREENS} for a Big Screen. Try again once one has left.`;
    actions = ["retry", "leave"];
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
  } else if (status === "connected" && state?.mode === "send") {
    title = "Copy cards";
    ({ message, actions } = offerText(readable));
    if (stale) message = "Not hearing from the other device. It may be asleep or out of range.";
  } else if (status === "connected" && state?.wall) {
    title = `Screen ${state.wall.n} of ${state.wall.of}`;
    message = stale
      ? "Not hearing from the other device. It may be asleep or out of range."
      : `Joined ${readable} as part of a Big Screen. This screen shows its piece of each card when the other device presses play. Turn every screen's brightness up to the same level so they match.`;
    actions = ["fullscreen", "leave"];
    if (stale) badge = "Connection looks stale";
  } else if (status === "connected") {
    title = "Ready";
    message = stale
      ? "Not hearing from the other device. It may be asleep or out of range."
      : `Joined ${readable}. The cards appear here when the other device presses play. Turn this screen's brightness up so they read across the room.`;
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

  const ready = offer !== null && picturesPending() === 0 && !copying;
  el.add.hidden = !actions.includes("copy");
  el.replace.hidden = !actions.includes("copy");
  el.add.disabled = !ready;
  el.replace.disabled = !ready;
  el.replace.classList.toggle("btn-danger", replaceArmed);
  setText(el.replaceLabel, replaceArmed ? "Tap again to replace" : "Replace my cards");

  // The badge only matters over a card; with no card, the panel says it.
  const showBadge = badge !== "" && shownKey !== "";
  el.badge.hidden = !showBadge;
  setText(el.badge, showBadge ? badge : "");

  // Over everything, card included, while the host has the numbers showing.
  const wall = status === "connected" && !ended ? state?.wall : null;
  el.number.hidden = !wall?.identify;
  if (wall?.identify) {
    setText(el.numberValue, String(wall.n));
    setText(el.numberOf, `of ${wall.of}`);
  }
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function offerText(readable) {
  if (!offer) {
    return { message: `Joined ${readable}. Getting the cards...`, actions: ["leave"] };
  }

  const cards = `${plural(offer.cards.length, "card")} from the other device.`;
  if (copying) return { message: `${cards} Copying...`, actions: ["copy", "leave"] };

  const pending = picturesPending();
  if (pending > 0) {
    const got = offer.imageIds.size - pending;
    return {
      message: `${cards} Receiving pictures, ${got} of ${offer.imageIds.size}...`,
      actions: ["copy", "leave"],
    };
  }

  const lost = offer.missing.size
    ? ` ${plural(offer.missing.size, "picture")} could not be sent and will be left out.`
    : "";
  return {
    message:
      offer.cards.length === 1
        ? `${cards}${lost} Add it to yours, or replace yours with it.`
        : `${cards}${lost} Add them to yours, or replace yours with them.`,
    actions: ["copy", "leave"],
  };
}

/* ---- copying the deck ---- */

function disarmReplace() {
  clearTimeout(armTimer);
  armTimer = null;
  replaceArmed = false;
}

async function copyCards(replace) {
  if (!offer || copying || picturesPending() > 0) return;

  if (replace && !replaceArmed) {
    replaceArmed = true;
    armTimer = setTimeout(() => {
      disarmReplace();
      renderPanel();
    }, ARM_MS);
    renderPanel();
    return;
  }

  disarmReplace();
  copying = true;
  renderPanel();

  // Taken now: a fresh copy of the deck arriving mid-write must not mix in.
  const { cards, blobs } = offer;
  try {
    await onImport(cards, blobs, { replace });
  } catch {
    copying = false;
    renderPanel();
    return;
  }

  copying = false;
  guest?.send({ type: "imported" });
  leaveViewer();
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
  dropOffer();
  state = null;
  clockSamples = [];
  status = "idle";
  ended = false;
  removed = false;
  outdated = false;
  full = false;
  clearTimeout(resizeTimer);
  showNothing();
  el.viewer.classList.remove("lining");

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

/* This screen is put down and left, so it must not dim or lock. The browser
   lets go of the lock whenever the page is hidden, and some let go on their
   own (a battery saver turning on), so it is asked for again whenever it
   goes and the page can hold it. A page cannot turn the brightness up; the
   panel asks for that. */
let wakeAsking = false;

async function requestWakeLock() {
  if (!open || wakeLock || wakeAsking || document.visibilityState !== "visible") return;
  wakeAsking = true;
  try {
    const lock = (await navigator.wakeLock?.request("screen")) ?? null;
    wakeLock = lock;
    lock?.addEventListener("release", () => {
      if (wakeLock !== lock) return;
      wakeLock = null;
      // Hidden pages get it back on visibilitychange instead.
      setTimeout(requestWakeLock, 1000);
    });
  } catch {
    /* unsupported, or refused until the page is touched; tried again then */
  } finally {
    wakeAsking = false;
  }
}

function releaseWakeLock() {
  const lock = wakeLock;
  wakeLock = null;
  lock?.release().catch(() => {});
}

/* `importCards(cards, pictures, { replace })` writes a sent deck into this
   device's own: `pictures` maps the image ids the cards use to their blobs,
   and an image layer whose id is not in it is a picture that never came. */
export function initViewer({ importCards } = {}) {
  if (importCards) onImport = importCards;

  el.viewer = document.getElementById("viewer");
  el.safe = document.getElementById("viewerSafe");
  el.wall = document.getElementById("viewerWall");
  el.canvas = document.getElementById("viewerCanvas");
  el.panel = el.viewer.querySelector(".viewer-panel");
  el.number = document.getElementById("viewerNumber");
  el.numberValue = document.getElementById("viewerNumberValue");
  el.numberOf = document.getElementById("viewerNumberOf");
  el.title = document.getElementById("viewerTitle");
  el.message = document.getElementById("viewerMessage");
  el.badge = document.getElementById("viewerBadge");
  el.retry = document.getElementById("viewerRetry");
  el.fullscreen = document.getElementById("viewerFullscreen");
  el.leave = document.getElementById("viewerLeave");
  el.add = document.getElementById("viewerAdd");
  el.replace = document.getElementById("viewerReplace");
  el.replaceLabel = document.getElementById("viewerReplaceLabel");

  el.add.addEventListener("click", () => copyCards(false));
  el.replace.addEventListener("click", () => copyCards(true));
  el.retry.addEventListener("click", () => {
    retryDelay = RETRY_FIRST_MS;
    join();
  });
  el.fullscreen.addEventListener("click", toggleFullscreen);
  el.leave.addEventListener("click", leaveViewer);
  document.getElementById("viewerFullscreenCorner").addEventListener("click", toggleFullscreen);
  document.getElementById("viewerExit").addEventListener("click", leaveViewer);
  document.addEventListener("fullscreenchange", renderPanel);

  // The shape of this screen is the shape of its piece of a Big Screen, and
  // going full screen or turning a phone changes it.
  window.addEventListener("resize", () => {
    if (!open) return;
    placeStage();
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      guest?.send({ type: "size", ...screenSize() });
    }, RESIZE_MS);
  });

  // Some browsers only grant the lock after the page is touched.
  el.viewer.addEventListener("pointerdown", requestWakeLock);
  document.addEventListener("fullscreenchange", requestWakeLock);

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
