/* Sharing the cards with another screen: the host's side, and the share
   sheet that starts either side. See STUN-p2p-spec.md at the repo root.

   This device is the host. It holds the deck and publishes a code; the other
   screen joins as the guest. The guest shows nothing until this device
   presses play, then shows the presented card full screen, and goes back to
   waiting when the presenter closes. Cards being edited never leave this
   device; only a card being presented does.

   Four ways to share, picked in the sheet:

   Mirror      both screens show the card.
   Extend      the other screen shows the card and this one becomes a
               presenter view: the same card smaller, with the next one
               beneath it.
   Big Screen  Extend across several screens at once. Each one joins with the
               same code and is given a place in a grid; together they show
               one card, each drawing only its own piece of it. This device
               is the presenter view, with the grid drawn over the card.
   Send        nothing is shown. The other device is sent the whole deck,
               hidden layers and pictures included, and can add it to its own
               cards or replace its own with it. The one time the deck leaves
               this device, and only because somebody picked it.

   Under any of the first three, a card with its ticker on (a switch on each
   card, see deck.js) has its words run together onto one line that rolls
   across the screens like a news ticker.

   The host is authoritative and sends a full snapshot twenty times a second.
   Snapshots carry no pictures: those go once each, in chunks, to a guest
   that says it lacks them, so a card with a photo costs its bytes once and
   a snapshot stays a few hundred bytes. */

import {
  Host,
  generateCode,
  isValidCode,
  normaliseCode,
  PROTOCOL_VERSION,
  CODE_LENGTH,
  MAX_SHARED_IMAGES,
  MAX_SCREENS,
} from "./p2p.js";
import { qrSvg } from "./qr.js";
import { fillImage, readTickerSpeed } from "./deck.js";
import { getImage, readSetting, writeSetting } from "./store.js";
import { closeModal, openModal, toast } from "./ui.js";
import { icon } from "./icons.js";
import { startViewing } from "./viewer.js";
import { showsTicker } from "./ticker.js";

const SNAPSHOT_MS = 50;
// A guest pings every half second. Silence for this long is a guest that
// has gone (a browser closed, a laptop lid shut) without its channel saying
// so, which can otherwise take tens of seconds.
const GUEST_SILENT_MS = 5000;

// Under PeerJS's own 16,300 byte chunk size once the message around it is
// counted, so the library never has to split a chunk of ours again.
const CHUNK_CHARS = 12000;
const BUFFER_HIGH = 1024 * 1024;

// A photograph straight off a phone is 12 megapixels and several megabytes.
// No screen this is shown on needs more than 1080p, so anything larger is
// scaled before it is sent.
const MAX_EDGE = 1920;
const KEEP_BYTES = 400 * 1024;
const PREPARED_LIMIT = 12;

const MODES = ["mirror", "extend", "bigscreen", "send"];
const MODE_NOTES = {
  mirror: "Both screens show the card.",
  extend: "The other screen shows the card. This one shows it smaller, with the next card beneath it.",
  bigscreen:
    "Several screens join with the same code and show one card together, each its own piece. This one shows it smaller, with the next card beneath it.",
  send: "The other device gets a copy of all your cards, pictures included, to add to its own or to replace them.",
};

// What a guest calls its screen, so a reconnect is recognised as the same
// one. Made by viewer.js.
const SCREEN_ID = /^[a-z0-9]{6,24}$/;
// The card as it is made in the editor, which is the shape the other screen
// draws it in under Extend.
const CARD_ASPECT = 16 / 10;
// A screen that has not said how big it is, in millimetres: a phone on its
// side.
const DEFAULT_SIZE = { w: 150, h: 70 };
// Between two screens of a Big Screen, the part of the card that lands on
// their bezels, in millimetres. Two phones in cases side by side lose about
// eight. Each seam between two columns or two rows has its own, set by
// dragging it in the sheet until the lines on the screens meet straight:
// a tenth of a millimetre for every pixel dragged, so it can be got exactly.
const GAP_DEFAULT = 8;
const GAP_STEP = 1;
const GAP_MAX = 60;
const SEAM_PER_PX = 0.1;
const SEAM_KEY_STEP = 0.5;
// The lines stay up on the screens this long after a seam is let go, to
// judge it by.
const LINES_LINGER_MS = 3000;
// A screen that drops is held its place this long, for a blip in the wifi or
// a reload, and then let go. One that leaves on purpose goes at once.
const LOST_MS = 8000;
// Two screens trading places in the grid. The screens themselves slide for
// the same time, in viewer.js.
const SWAP_MS = 420;

let frame = () => null;
let host = null;
let status = { status: "idle" };
let retriedTaken = false;
let beatTimer = null;
let shownCode = "";

// Guest peer id -> { heard: last time anything arrived, images: ids it says
// it holds, offered: ids sent to it and not yet confirmed, screen: its
// screen id once it has said hello, size: { w, h } in millimetres }.
const guests = new Map();
let pumping = false;
const prepared = new Map(); // image id -> Promise<{ mime, data }>

/* Big Screen. `order` is the screens by place, left to right and then down,
   and a screen's number is its place plus one. A screen that drops keeps its
   place for LOST_MS, so a blip brings it back to the same piece of the card;
   after that, or when it leaves on purpose or the presenter removes it, the
   screens after it close up. `cols` is null until somebody picks it, which
   puts every screen in one row. `seamsX` and `seamsY` are the bezels at each
   seam between two columns and two rows, in millimetres, which the card runs
   on behind so a line crossing from one screen to the next stays straight;
   `gap` is the width for a seam not yet set. `lines` puts lines across every
   screen to set them by. */
const wall = { order: [], cols: null, identify: false, lines: false, gap: GAP_DEFAULT, seamsX: [], seamsY: [] };
// Screen id -> { w, h } in millimetres, kept after a screen drops, so the
// rest do not move about while it comes back.
const sizes = new Map();
let picked = null; // the place tapped first, waiting for a second to swap with
const lostAt = new Map(); // screen id -> when it was first seen not connected
let drag = null; // the seam being dragged: { seam, axis, index, pointer, from, start }
let linesUntil = 0;

const el = {};

/* ---- what the rest of the app reads ---- */

export function shareMode() {
  const mode = readSetting("shareMode");
  return MODES.includes(mode) ? mode : "mirror";
}

/* What the presenter view draws over the card while it is a Big Screen, or
   null: { rows, aspect: the whole wall's width over its height, cells:
   [{ number, online, blank, x, y, w, h }] with the place of each screen as
   fractions of the wall, identify }. Blank cells are the places past the
   last screen in a short bottom row. */
export function bigScreen() {
  if (!host || shareMode() !== "bigscreen") return null;
  const { rows } = wallLayout();
  const geo = wallGeometry();
  return {
    rows,
    aspect: geo.width / geo.height,
    cells: geo.cells.map((cell, i) => ({
      number: i + 1,
      online: i < wall.order.length && isOnline(wall.order[i]),
      blank: i >= wall.order.length,
      x: cell.left / geo.width,
      y: cell.top / geo.height,
      w: cell.w / geo.width,
      h: cell.h / geo.height,
    })),
    identify: wall.identify,
  };
}

export function isHosting() {
  return host !== null;
}

export function hostStatus() {
  return status.status;
}

/* Sends the current picture now rather than on the next beat, so pressing
   play or stepping a card reaches the other screen without the wait. */
export function shareNow() {
  if (!host || host.links.size === 0) return;
  sendSnapshots();
  pumpImages();
}

/* The deck was edited and saved. A guest about to copy it gets the edit,
   rather than whatever the deck was when it joined. */
export function shareDeckChanged() {
  sendDeck();
  pumpImages();
}

/* ---- hosting ---- */

/* `ask`: from the Start button, so the Android app may ask for what sharing
   with no wifi needs. Never when a reload resumes sharing on its own. */
async function startHosting({ ask = false } = {}) {
  if (host) return;

  const stored = readSetting("hostCode");
  const code = isValidCode(stored) ? stored : generateCode();
  writeSetting("hostCode", code);
  writeSetting("shareRole", "host");

  const h = new Host({ maxGuests: maxGuestsFor(shareMode()) });
  host = h;
  status = { status: "connecting" };
  loadWall();
  showCode(code);

  h.addEventListener("status", ({ detail }) => {
    if (host !== h) return;
    // Another tab, or the broker not yet releasing the id after a reload.
    // One fresh code, silently; a second collision in a row is not stale
    // state and retrying would only hammer the broker.
    if (detail.taken && !retriedTaken) {
      retriedTaken = true;
      restartWithFreshCode();
      return;
    }
    if (detail.status === "waiting") retriedTaken = false;
    status = detail;
    changed();
  });

  h.addEventListener("join", ({ detail }) => {
    if (host !== h) return;
    // A new guest, or the same screen after a reload: either way it holds no
    // pictures until it says otherwise, and has no place until its hello.
    guests.set(detail.id, { heard: Date.now(), images: new Set(), offered: new Set(), screen: null, size: null });
  });

  h.addEventListener("leave", ({ detail }) => guests.delete(detail.id));

  h.addEventListener("message", ({ detail: { message, from } }) => {
    if (host === h) onMessage(message, from);
  });

  beatTimer = setInterval(beat, SNAPSHOT_MS);
  changed();

  try {
    await h.start(code, { ask });
  } catch {
    if (host !== h) return;
    stopHosting();
    writeSetting("shareRole", null);
    status = { status: "error", message: "Could not load sharing. Check your connection." };
    changed();
  }
}

/* `tellGuest` for stopping on purpose: the guest hears `end` and says the
   sharing ended, rather than reporting a dropped connection and trying to
   come back to a code that is gone. */
function stopHosting({ tellGuest = false } = {}) {
  const h = host;
  if (!h) return;

  host = null;
  clearInterval(beatTimer);
  beatTimer = null;
  guests.clear();
  wall.identify = false;
  wall.lines = false;
  picked = null;
  drag = null;
  lostAt.clear();
  status = { status: "idle" };

  if (tellGuest && h.links.size > 0) {
    h.send({ type: "end" });
    // Long enough for `end` to leave; close() tears the channel down at once.
    setTimeout(() => h.close(), 300);
  } else {
    h.close();
  }
}

function restartWithFreshCode({ tellGuest = false } = {}) {
  stopHosting({ tellGuest });
  writeSetting("hostCode", null);
  startHosting();
}

function onMessage(message, from) {
  const guest = guests.get(from);
  if (guest) guest.heard = Date.now();

  switch (message.type) {
    case "hello":
      if (message.v !== PROTOCOL_VERSION) {
        host.send({ type: "outdated" }, from);
        return;
      }
      if (guest) {
        guest.size = readSize(message);
        claimScreen(guest, message.screen, from);
      }
      sendSnapshots(from);
      sendDeck(from);
      break;
    case "size":
      if (!guest) break;
      guest.size = readSize(message);
      if (guest.screen && guest.size) sizes.set(guest.screen, guest.size);
      if (shareMode() === "bigscreen") wallChanged();
      break;
    case "imported":
      toast("The other device copied your cards.");
      break;
    case "have":
      if (!guest) break;
      guest.images = readImageList(message.images);
      guest.images.forEach((id) => guest.offered.delete(id));
      pumpImages();
      break;
    case "bye": {
      // One screen of several leaving takes nothing from the rest, and a Big
      // Screen keeps its code while it is being put together. Otherwise the
      // code is spent: one shown to a room in this session should not keep
      // working in the next. A screen that left on purpose gives up its
      // place, and the rest close up.
      const screen = guest?.screen;
      dropGuest(from);
      if (screen && !isOnline(screen)) forgetScreen(screen);
      if (shareMode() === "bigscreen" || host.links.size > 0) changed();
      else restartWithFreshCode();
      break;
    }
    default:
      // `ping`, and anything from a newer build. Never thrown on.
      break;
  }
}

function dropGuest(id) {
  const link = host.links.get(id);
  guests.delete(id);
  if (!link) return;
  host.drop(link);
  host.refreshStatus();
}

/* Let one screen go because the presenter said so. It is told, and shows
   that it was removed rather than trying to come back. */
function removeGuest(id) {
  const link = host?.links.get(id);
  guests.delete(id);
  if (link) host.kick(link, { type: "removed" });
}

/* A guest's screen in millimetres, from its own say-so: its size in CSS
   pixels and its guess at how many of those make a millimetre. Kept to sizes
   a screen can have. A guest from before the guess was sent is taken for a
   phone, the usual case. */
function readSize({ w, h, ppm }) {
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return null;
  const per = Number.isFinite(ppm) ? Math.min(Math.max(ppm, 2), 12) : 160 / 25.4;
  const aspect = Math.min(Math.max(w / h, 0.25), 4);
  const width = Math.min(Math.max(w / per, 20), 3000);
  return { w: width, h: width / aspect };
}

/* ---- Big Screen ---- */

function maxGuestsFor(mode) {
  return mode === "bigscreen" ? MAX_SCREENS : 1;
}

function claimScreen(guest, screen, from) {
  if (typeof screen !== "string" || !SCREEN_ID.test(screen)) return;
  // The same screen back on a new connection before its old one timed out.
  for (const [id, other] of [...guests]) {
    if (id !== from && other.screen === screen) dropGuest(id);
  }
  guest.screen = screen;
  if (guest.size) sizes.set(screen, guest.size);
  if (shareMode() === "bigscreen") placeScreen(screen);
  changed();
}

/* A screen new to this wall takes the next place, or, once every place is
   taken, the first one whose screen is not connected. There is always one:
   no more screens can be connected than there are places. */
function placeScreen(screen) {
  if (wall.order.includes(screen)) return;
  if (wall.order.length < MAX_SCREENS) {
    wall.order.push(screen);
  } else {
    const free = wall.order.findIndex((s) => !isOnline(s));
    if (free < 0) return;
    wall.order[free] = screen;
  }
  saveWall();
}

// Out of the wall, its place closed up by the screens after it.
function forgetScreen(screen) {
  const i = wall.order.indexOf(screen);
  lostAt.delete(screen);
  if (i < 0) return;
  wall.order.splice(i, 1);
  picked = null;
  wallChanged();
}

function removeScreen(place) {
  const screen = wall.order[place];
  if (!screen) return;
  for (const [id, guest] of [...guests]) if (guest.screen === screen) removeGuest(id);
  forgetScreen(screen);
}

/* Screens that dropped and have not come back within LOST_MS are let go, so
   the wall is only ever the screens that are there. */
function forgetLost(now) {
  const lost = [];
  for (const screen of wall.order) {
    if (isOnline(screen)) lostAt.delete(screen);
    else if (!lostAt.has(screen)) lostAt.set(screen, now);
    else if (now - lostAt.get(screen) > LOST_MS) lost.push(screen);
  }
  if (!lost.length) return;
  lost.forEach((screen) => lostAt.delete(screen));
  wall.order = wall.order.filter((screen) => !lost.includes(screen));
  picked = null;
  wallChanged();
}

function isOnline(screen) {
  for (const guest of guests.values()) if (guest.screen === screen) return true;
  return false;
}

function onlineCount() {
  return wall.order.filter(isOnline).length;
}

function wallLayout() {
  const count = Math.max(1, wall.order.length);
  const cols = Math.min(Math.max(wall.cols ?? count, 1), count);
  return { count, cols, rows: Math.ceil(count / cols) };
}

// The middle of what the placed screens say, the size given to a blank
// place, so one odd screen does not set it.
function middleSize() {
  const known = wall.order.map((screen) => sizes.get(screen)).filter(Boolean);
  if (!known.length) return DEFAULT_SIZE;
  const mid = (list) => list.sort((a, b) => a - b)[Math.floor(list.length / 2)];
  return { w: mid(known.map((s) => s.w)), h: mid(known.map((s) => s.h)) };
}

// The bezels at each seam, one per gap between two columns (`x`) or two
// rows (`y`). A seam nobody has set takes the last width set for them all.
function seams(axis, count) {
  const list = axis === "x" ? wall.seamsX : wall.seamsY;
  return Array.from({ length: Math.max(0, count) }, (_, i) => (Number.isFinite(list[i]) ? list[i] : wall.gap));
}

function setSeam(axis, index, mm) {
  const list = axis === "x" ? wall.seamsX : wall.seamsY;
  const { cols, rows } = wallLayout();
  const filled = seams(axis, Math.max(axis === "x" ? cols - 1 : rows - 1, index + 1));
  filled[index] = clampGap(mm);
  list.length = 0;
  list.push(...filled);
}

function clampGap(mm) {
  return Math.round(Math.min(Math.max(mm, 0), GAP_MAX) * 10) / 10;
}

/* The wall laid out in millimetres, so screens of different sizes each show
   the piece of the card that is really in front of them. Every column is as
   wide as its widest screen and every row as tall as its tallest, each
   screen centred in its cell, with each seam's own bezels between cells. A
   blank place in a short bottom row is given the usual size. Cells are
   { left, top, w, h }, one for every place in the grid, screens first. */
function wallGeometry() {
  const { cols, rows } = wallLayout();
  const usual = middleSize();
  const sizeAt = (i) => (i < wall.order.length && sizes.get(wall.order[i])) || usual;

  const colW = Array(cols).fill(0);
  const rowH = Array(rows).fill(0);
  for (let i = 0; i < cols * rows; i++) {
    const { w, h } = sizeAt(i);
    colW[i % cols] = Math.max(colW[i % cols], w);
    rowH[Math.floor(i / cols)] = Math.max(rowH[Math.floor(i / cols)], h);
  }

  const gapX = seams("x", cols - 1);
  const gapY = seams("y", rows - 1);
  const sum = (list, n) => list.slice(0, n).reduce((a, b) => a + b, 0);
  const colX = colW.map((_, i) => sum(colW, i) + sum(gapX, i));
  const rowY = rowH.map((_, i) => sum(rowH, i) + sum(gapY, i));
  const cells = Array.from({ length: cols * rows }, (_, i) => {
    const { w, h } = sizeAt(i);
    const c = i % cols;
    const r = Math.floor(i / cols);
    return { left: colX[c] + (colW[c] - w) / 2, top: rowY[r] + (rowH[r] - h) / 2, w, h };
  });

  return {
    width: colX[cols - 1] + colW[cols - 1],
    height: rowY[rows - 1] + rowH[rows - 1],
    cells,
    // Where each seam's bezels are, for the handles in the sheet.
    seamsX: gapX.map((gap, i) => ({ at: colX[i] + colW[i], gap })),
    seamsY: gapY.map((gap, i) => ({ at: rowY[i] + rowH[i], gap })),
  };
}

/* Where one screen sits, sent in its snapshot. Null for a screen with no
   place, which draws the whole card rather than nothing. `box` is the whole
   wall measured in this screen: where it starts and how big it is, in
   widths and heights of this screen. */
function wallTile(screen) {
  const i = wall.order.indexOf(screen);
  if (i < 0) return null;
  const { count, cols, rows } = wallLayout();
  const geo = wallGeometry();
  const cell = geo.cells[i];
  const round = (n) => Math.round(n * 10000) / 10000;
  return {
    n: i + 1,
    of: count,
    col: i % cols,
    row: Math.floor(i / cols),
    cols,
    rows,
    identify: wall.identify,
    lines: linesShowing(),
    box: {
      x: round(-cell.left / cell.w),
      y: round(-cell.top / cell.h),
      w: round(geo.width / cell.w),
      h: round(geo.height / cell.h),
    },
  };
}

function loadWall() {
  wall.order = [...new Set((readSetting("wallOrder") || "").split(","))]
    .filter((s) => SCREEN_ID.test(s))
    .slice(0, MAX_SCREENS);
  const cols = Number.parseInt(readSetting("wallCols"), 10);
  wall.cols = cols >= 1 && cols <= MAX_SCREENS ? cols : null;
  const gap = Number.parseFloat(readSetting("wallGap"));
  wall.gap = gap >= 0 && gap <= GAP_MAX ? clampGap(gap) : GAP_DEFAULT;
  const list = (name) =>
    (readSetting(name) || "")
      .split(",")
      .slice(0, MAX_SCREENS)
      .map(Number.parseFloat)
      .map((mm) => (Number.isFinite(mm) ? clampGap(mm) : wall.gap));
  wall.seamsX = list("wallSeamsX");
  wall.seamsY = list("wallSeamsY");
  // Places kept from before a reload are held for their screens as if they
  // had just dropped, and let go if they do not come back.
  lostAt.clear();
}

function saveWall() {
  writeSetting("wallOrder", wall.order.length ? wall.order.join(",") : null);
  writeSetting("wallCols", wall.cols);
  writeSetting("wallGap", wall.gap);
  writeSetting("wallSeamsX", wall.seamsX.length ? wall.seamsX.join(",") : null);
  writeSetting("wallSeamsY", wall.seamsY.length ? wall.seamsY.join(",") : null);
}

function clearWall() {
  wall.order = [];
  wall.cols = null;
  picked = null;
  lostAt.clear();
  saveWall();
}

// Lines across the whole wall on every screen: while a seam is being
// dragged, a moment after, and while the presenter has them on.
function linesShowing() {
  return wall.lines || drag !== null || Date.now() < linesUntil;
}

// A change to the wall reaches the screens at once, not on the next beat.
function wallChanged() {
  saveWall();
  changed();
  shareNow();
}

function readImageList(list) {
  if (!Array.isArray(list)) return new Set();
  return new Set(list.slice(0, MAX_SHARED_IMAGES).filter((id) => typeof id === "string" && id.length <= 64));
}

/* Twenty times a second: drop a guest that has gone quiet, send the
   snapshot, and keep any picture transfer moving. The snapshot is also the
   guest's heartbeat. */
function beat() {
  if (!host) return;

  const now = Date.now();
  for (const [id, guest] of [...guests]) {
    if (now - guest.heard > GUEST_SILENT_MS) dropGuest(id);
  }
  forgetLost(now);

  if (host.links.size === 0) return;
  sendSnapshots();
  pumpImages();
}

/* ---- the snapshot ---- */

/* One snapshot for every guest, except on a Big Screen, where each is told
   its own place. A screen yet to say hello has no place to be told, so it
   waits for one rather than drawing the whole card. */
function sendSnapshots(to) {
  if (shareMode() !== "bigscreen") {
    host.send(snapshot(), to);
    return;
  }
  for (const [id, guest] of guests) {
    if ((!to || id === to) && guest.screen) host.send(snapshot(guest.screen), id);
  }
}

function snapshot(screen) {
  const f = frame();
  const root = document.documentElement;
  const mode = shareMode();
  const sending = mode === "send";
  const message = {
    type: "state",
    mode: sending ? "send" : "show",
    presenting: false,
    // The host's clock, which the screens roll a ticker by so they agree.
    clock: Date.now(),
    theme: { color: root.getAttribute("data-color-theme"), mode: root.getAttribute("data-mode") },
  };
  if (mode === "bigscreen" && screen) message.wall = wallTile(screen);
  // The shape the card is seen in here, so a screen of another shape draws
  // the same picture inside its own rather than cropping it: this screen's
  // own under Mirror, the editor's card under Extend.
  else if (mode === "mirror") message.shape = Math.round((window.innerWidth / window.innerHeight) * 1000) / 1000;
  else if (mode === "extend") message.shape = CARD_ASPECT;

  // Nothing about the card until play is pressed: the other screen waits,
  // and what is being edited stays on this one. Sending shows nothing at
  // all; the deck goes separately, in sendDeck().
  if (!sending && f?.presenting && f.card) {
    message.presenting = true;
    message.card = wireCard(f.card);
    // The card's own ticker, which the presenter here draws the same.
    if (showsTicker(f.card)) message.ticker = { speed: readTickerSpeed(f.card.tickerSpeed) };
  }

  return message;
}

// Only what drawing needs. Hidden layers are left behind rather than sent
// with a flag, since the other screen has no use for them. Whether the
// picture fills the card is settled here: a hidden second picture stops it,
// and the other screen never hears of that one.
function wireCard(card) {
  const filling = fillImage(card);
  return {
    layout: card.layout,
    wrap: card.wrap !== false,
    layers: card.layers
      .filter((layer) => !layer.hidden)
      .map((layer) =>
        layer.type === "image"
          ? { type: "image", imageId: layer.imageId, fit: layer.fit, fill: layer === filling, focus: layer.focus }
          : { type: "text", text: layer.text, size: layer.size, align: layer.align }
      ),
  };
}

/* ---- sending the deck ---- */

function deckCards() {
  return frame()?.deck?.cards ?? [];
}

// A copy rather than a picture, so hidden layers go too, flagged, and come
// out hidden on the other device as they were here.
function wireDeckCard(card) {
  return {
    layout: card.layout,
    layers: card.layers.map((layer) =>
      layer.type === "image"
        ? {
            type: "image",
            imageId: layer.imageId,
            fit: layer.fit,
            fill: layer.fill,
            focus: layer.focus,
            hidden: layer.hidden,
          }
        : { type: "text", text: layer.text, size: layer.size, align: layer.align, hidden: layer.hidden }
    ),
    ticker: card.ticker === true,
    tickerSpeed: card.tickerSpeed,
    wrap: card.wrap !== false,
  };
}

// The whole deck, sent when a guest arrives, when Send is picked, and after
// every save while it is picked. Words only: the pictures follow through
// pumpImages() like any others.
function sendDeck(to) {
  if (!host || host.links.size === 0 || shareMode() !== "send") return;
  host.send({ type: "deck", cards: deckCards().map(wireDeckCard) }, to);
}

/* ---- pictures ---- */

function wantedImages() {
  if (shareMode() === "send") {
    // Every picture in the deck, hidden ones included, in card order.
    const ids = deckCards().flatMap((card) =>
      card.layers.filter((l) => l.type === "image").map((l) => l.imageId)
    );
    return [...new Set(ids)].slice(0, MAX_SHARED_IMAGES);
  }

  const f = frame();
  if (!f) return [];
  // The card on screen first, then its neighbours, so stepping to the next
  // card finds its picture already there.
  return [f.card, ...(f.nearby || [])]
    .filter(Boolean)
    .flatMap((card) => card.layers.filter((l) => l.type === "image" && !l.hidden).map((l) => l.imageId));
}

/* One picture to one guest at a time, the guests in the order they came.
   Every screen of a Big Screen wants the same pictures, so each is sent the
   card's own before the next gets anything. */
function pumpImages() {
  if (pumping || !host) return;
  const wanted = wantedImages();
  for (const [peerId, guest] of guests) {
    const link = host.links.get(peerId);
    const id = link && wanted.find((imageId) => !guest.images.has(imageId) && !guest.offered.has(imageId));
    if (id) {
      sendImage(host, link, guest, id);
      return;
    }
  }
}

async function sendImage(h, link, guest, id) {
  pumping = true;
  guest.offered.add(id);
  // The guest is a fresh entry whenever its screen joins again.
  const current = () => host === h && h.links.get(link.peer) === link && guests.get(link.peer) === guest;

  try {
    const { mime, data } = await preparedImage(id);
    const total = Math.max(1, Math.ceil(data.length / CHUNK_CHARS));

    for (let seq = 0; seq < total; seq++) {
      // The guest may have gone, or been replaced, mid transfer. The next
      // one asks again from the start.
      while (current() && congested(link)) await wait(25);
      if (!current()) return;

      h.send(
        { type: "image", id, mime, seq, total, data: data.slice(seq * CHUNK_CHARS, (seq + 1) * CHUNK_CHARS) },
        link.peer
      );
      if (seq % 8 === 7) await wait(0);
    }
  } catch {
    // Missing from storage or undecodable. Left in `offered`, so it is not
    // tried again on every beat; the card shows without it. Said, so a
    // guest copying the deck is not left waiting on it.
    if (current()) h.send({ type: "noimage", id }, link.peer);
  } finally {
    pumping = false;
  }
}

function congested(link) {
  return (link.dataChannel?.bufferedAmount ?? 0) > BUFFER_HIGH || (link.bufferSize ?? 0) > 0;
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function preparedImage(id) {
  if (!prepared.has(id)) {
    prepared.set(id, prepareImage(id));
    if (prepared.size > PREPARED_LIMIT) prepared.delete(prepared.keys().next().value);
  }
  return prepared.get(id);
}

async function prepareImage(id) {
  const blob = await getImage(id);
  if (!blob) throw new Error("image missing");
  const small = await shrink(blob);
  return { mime: small.type || blob.type || "image/png", data: await toBase64(small) };
}

async function shrink(blob) {
  let bitmap;
  try {
    bitmap = await createImageBitmap(blob);
  } catch {
    // SVG in some browsers, or something createImageBitmap cannot read.
    // Sent as it is; the other screen's <img> will manage.
    return blob;
  }

  const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
  if (scale === 1 && blob.size <= KEEP_BYTES) {
    bitmap.close();
    return blob;
  }

  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();

  // WebP keeps transparency and is small. Safari cannot encode it and hands
  // back a PNG instead, so JPEG is the fallback for pictures that had no
  // transparency to keep.
  let out = await toBlob(canvas, "image/webp", 0.85);
  if (out?.type !== "image/webp") {
    out = await toBlob(canvas, blob.type === "image/png" || blob.type === "image/gif" ? "image/png" : "image/jpeg", 0.85);
  }
  return out && out.size < blob.size ? out : blob;
}

function toBlob(canvas, type, quality) {
  return new Promise((resolve) => canvas.toBlob(resolve, type, quality));
}

function toBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1] || "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/* ---- the sheet ---- */

function joinUrl(code) {
  return `${location.origin}/?join=${code}`;
}

function showCode(code) {
  if (code === shownCode) return;
  shownCode = code;

  el.code.textContent = `${code.slice(0, 3)} ${code.slice(3)}`;
  el.link.textContent = joinUrl(code);
  el.qr.innerHTML = "";
  el.qr.hidden = false;

  qrSvg(joinUrl(code))
    .then((svg) => {
      if (shownCode === code) el.qr.innerHTML = svg;
    })
    .catch(() => {
      // The code and the link are on screen either way.
      if (shownCode === code) el.qr.hidden = true;
    });
}

/* In the Android app: whether phones can join with no wifi, over Nearby
   (js/nearby.js), and what to do if not. Nothing in a browser. */
function nearbyText() {
  switch (host?.nearby) {
    case "ready":
      return host.online
        ? " Phones with the uwuFlash app can also join with no wifi."
        : " No internet, so only phones with the uwuFlash app nearby can join.";
    case "bt-off":
      return " Turn on Bluetooth so phones with the uwuFlash app can join with no wifi.";
    case "location-off":
      return " Turn on location so phones with the uwuFlash app can join with no wifi.";
    case "denied":
    case "needs-permission":
      return " To let phones join with no wifi, allow uwuFlash Nearby devices in Android's settings.";
    default:
      return "";
  }
}

function statusText() {
  switch (status.status) {
    case "connecting":
      return "Starting...";
    case "waiting":
      return (shareMode() === "bigscreen"
        ? "Waiting for screens to join. Open the code on each of them."
        : "Waiting for the other screen to join.") + nearbyText();
    case "connected":
      if (shareMode() === "bigscreen") {
        const n = onlineCount();
        return `${n} screen${n === 1 ? "" : "s"} joined. Together they show your cards when you press play.`;
      }
      return shareMode() === "send"
        ? "Connected. The other device can now copy your cards."
        : "Connected. The other screen shows your cards when you press play.";
    case "error":
      return status.message || "The connection failed.";
    default:
      return "";
  }
}

function renderSheet() {
  const mode = shareMode();
  el.modeButtons.forEach((btn) => {
    const active = btn.dataset.shareMode === mode;
    btn.classList.toggle("active", active);
    btn.setAttribute("aria-pressed", String(active));
  });
  el.modeNote.textContent = MODE_NOTES[mode];

  el.idle.hidden = host !== null;
  el.live.hidden = host === null;
  el.status.textContent = host ? statusText() : "";
  el.startNote.hidden = host !== null || status.status !== "error";
  el.startNote.textContent = host === null && status.status === "error" ? statusText() : "";

  el.button.classList.toggle("live", host !== null);
  el.button.setAttribute("aria-label", host ? "Sharing screen" : "Share screen");

  renderWall();
  renderGuests();
}

/* The screens of a Big Screen as they sit, numbered by place, drawn where
   they are on the wall with the bezels between them to scale. Tapping one
   and then another swaps them, which is how the grid here is made to match
   the screens on the table: show the numbers, see which is where, swap.
   Each seam between two columns or rows is a handle; dragging it sets the
   bezels there while the screens show lines to line up. */
function renderWall() {
  const show = host !== null && shareMode() === "bigscreen";
  el.wall.hidden = !show;
  if (!show) return;

  // Drawn afresh, the handle under the finger would be lost mid drag. The
  // rest catches up when it is let go.
  if (drag) {
    layoutMap();
    return;
  }

  const { count, cols } = wallLayout();
  const empty = wall.order.length === 0;
  if (picked !== null && picked >= wall.order.length) picked = null;

  el.wallEmpty.hidden = !empty;
  el.wallMap.hidden = empty;
  el.wallMap.classList.toggle("identifying", wall.identify);
  const geo = wallGeometry();
  const tiles = wall.order.map((screen, i) => {
    const online = isOnline(screen);
    const label = `Screen ${i + 1}${online ? "" : ", reconnecting"}`;
    return `<div class="wall-tile${online ? "" : " offline"}${picked === i ? " picked" : ""}" data-tile="${i}">
        <button class="wall-pick" type="button" data-place="${i}" aria-pressed="${picked === i}" aria-label="${label}">
          <span class="wall-num">${i + 1}</span>${online ? "" : '<span class="wall-off">Reconnecting</span>'}
        </button>
        <button class="wall-remove" type="button" data-remove="${i}" aria-label="Remove screen ${i + 1}">${icon("close")}</button>
      </div>`;
  });
  const handle = (axis, i) => {
    const between = axis === "x" ? `columns ${i + 1} and ${i + 2}` : `rows ${i + 1} and ${i + 2}`;
    return `<div class="wall-seam ${axis}" data-seam="${axis}" data-index="${i}" role="slider" tabindex="0"
        aria-orientation="${axis === "x" ? "horizontal" : "vertical"}" aria-label="Bezels between ${between}"
        aria-valuemin="0" aria-valuemax="${GAP_MAX}"><span class="wall-seam-value"></span></div>`;
  };
  el.wallMap.innerHTML =
    tiles.join("") +
    geo.seamsX.map((_, i) => handle("x", i)).join("") +
    geo.seamsY.map((_, i) => handle("y", i)).join("");
  layoutMap(geo);

  el.wallHint.hidden = wall.order.length < 2;
  el.wallHint.textContent =
    picked === null
      ? "Tap two screens to swap them. Drag a line between two screens until the lines on them meet straight."
      : `Now tap the screen to swap with ${picked + 1}.`;

  el.wallCols.textContent = `${cols} across`;
  el.wallFewer.disabled = cols <= 1;
  el.wallMore.disabled = cols >= count;

  const all = [...geo.seamsX, ...geo.seamsY].map((s) => s.gap);
  const low = all.length ? Math.min(...all) : wall.gap;
  const high = all.length ? Math.max(...all) : wall.gap;
  el.wallGap.textContent =
    high === 0 ? "No bezels" : low === high ? `Bezels ${mm(low)}` : `Bezels ${mm(low)} to ${mm(high)}`;
  el.wallGapLess.disabled = high <= 0;
  el.wallGapMore.disabled = low >= GAP_MAX;

  el.wallIdentify.setAttribute("aria-pressed", String(wall.identify));
  el.wallIdentify.classList.toggle("btn-primary", wall.identify);
  el.wallIdentifyLabel.textContent = wall.identify ? "Hide numbers" : "Show numbers";
  el.wallLines.setAttribute("aria-pressed", String(wall.lines));
  el.wallLines.classList.toggle("btn-primary", wall.lines);
  el.wallLinesLabel.textContent = wall.lines ? "Hide lines" : "Show lines";
}

function mm(n) {
  return `${Number.isInteger(n) ? n : n.toFixed(1)} mm`;
}

/* Places every tile and handle where the wall says, as percentages of the
   map, which is the wall's own shape. Cheap enough for every move of a
   drag. */
function layoutMap(geo = wallGeometry()) {
  const aspect = geo.width / geo.height;
  el.wallMap.style.setProperty("--aspect", aspect);
  // Narrower as the wall gets taller, so a column of screens fits the sheet.
  el.wallMap.style.setProperty("--map-width", `${Math.round(Math.min(340, Math.max(120, 220 * aspect)))}px`);
  const pct = (n, of) => `${((n / of) * 100).toFixed(3)}%`;

  el.wallMap.querySelectorAll("[data-tile]").forEach((tile) => {
    const cell = geo.cells[Number(tile.dataset.tile)];
    if (!cell) return;
    tile.style.left = pct(cell.left, geo.width);
    tile.style.top = pct(cell.top, geo.height);
    tile.style.width = pct(cell.w, geo.width);
    tile.style.height = pct(cell.h, geo.height);
  });

  el.wallMap.querySelectorAll("[data-seam]").forEach((handle) => {
    const across = handle.dataset.seam === "x";
    const seam = (across ? geo.seamsX : geo.seamsY)[Number(handle.dataset.index)];
    if (!seam) return;
    const middle = seam.at + seam.gap / 2;
    if (across) handle.style.left = pct(middle, geo.width);
    else handle.style.top = pct(middle, geo.height);
    handle.setAttribute("aria-valuenow", String(seam.gap));
    handle.setAttribute("aria-valuetext", mm(seam.gap));
    handle.firstElementChild.textContent = mm(seam.gap);
  });
}

/* Under Mirror, Extend and Send: the device that has joined, which can be
   let go from here. On a Big Screen the tiles do this instead. */
function renderGuests() {
  const list = host && shareMode() !== "bigscreen" ? [...guests.keys()].filter((id) => host.links.has(id)) : [];
  el.guests.hidden = list.length === 0;
  el.guests.innerHTML = list
    .map(
      (id, i) => `<li class="share-guest">
        <span class="share-guest-dot" aria-hidden="true"></span>
        <span class="share-guest-name">${list.length === 1 ? "Other screen" : `Screen ${i + 1}`}, connected</span>
        <button class="btn btn-quiet" type="button" data-remove-guest="${i}">${icon("close")}Remove</button>
      </li>`
    )
    .join("");
  el.guests.dataset.ids = list.join(" ");
}

function tileAt(place) {
  return el.wallMap.querySelector(`[data-tile="${place}"]`);
}

// The grid is drawn afresh on every change, so a tile is moved by starting
// it where it used to be drawn and letting it travel to where it is now.
function slideTile(place, from, to) {
  const tile = tileAt(place);
  if (!tile || reducedMotion()) return;
  tile.style.zIndex = "1";
  const slide = tile.animate(
    [{ transform: `translate(${from.left - to.left}px, ${from.top - to.top}px)` }, { transform: "none" }],
    { duration: SWAP_MS, easing: "cubic-bezier(0.65, 0, 0.35, 1)" }
  );
  slide.onfinish = slide.oncancel = () => tile.style.removeProperty("z-index");
}

// The stylesheet's reduced motion rule does not reach the Web Animations API.
function reducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
}

function seamValue(axis, index) {
  const { cols, rows } = wallLayout();
  return seams(axis, axis === "x" ? cols - 1 : rows - 1)[index] ?? wall.gap;
}

function endDrag() {
  if (!drag) return;
  drag.seam.classList.remove("dragging");
  drag = null;
  linesUntil = Date.now() + LINES_LINGER_MS;
  wallChanged();
}

function wireWall() {
  el.wallMap.addEventListener("click", (e) => {
    const remove = e.target.closest("[data-remove]");
    if (remove) {
      removeScreen(Number(remove.dataset.remove));
      return;
    }
    const tile = e.target.closest("[data-place]");
    if (!tile) return;
    const place = Number(tile.dataset.place);
    if (picked === null || picked === place) {
      picked = picked === place ? null : place;
      changed();
      return;
    }
    const other = picked;
    const before = [other, place].map((p) => tileAt(p).getBoundingClientRect());
    [wall.order[other], wall.order[place]] = [wall.order[place], wall.order[other]];
    picked = null;
    wallChanged();
    // Each from where the other one was, so the two are seen to trade.
    slideTile(other, before[1], before[0]);
    slideTile(place, before[0], before[1]);
  });

  // Dragging a seam: finely, so it can be set to the tenth of a millimetre
  // while watching the lines on the screens, and measured from where the
  // drag began so the map growing under the finger does not run away.
  el.wallMap.addEventListener("pointerdown", (e) => {
    const seam = e.target.closest("[data-seam]");
    if (!seam || drag) return;
    e.preventDefault();
    seam.setPointerCapture?.(e.pointerId);
    seam.focus({ preventScroll: true });
    const axis = seam.dataset.seam;
    const index = Number(seam.dataset.index);
    drag = { seam, axis, index, pointer: e.pointerId, from: axis === "x" ? e.clientX : e.clientY, start: seamValue(axis, index) };
    seam.classList.add("dragging");
    shareNow();
  });
  el.wallMap.addEventListener("pointermove", (e) => {
    if (!drag || e.pointerId !== drag.pointer) return;
    const moved = (drag.axis === "x" ? e.clientX : e.clientY) - drag.from;
    const next = clampGap(drag.start + moved * SEAM_PER_PX);
    if (next === seamValue(drag.axis, drag.index)) return;
    setSeam(drag.axis, drag.index, next);
    layoutMap();
    shareNow();
  });
  el.wallMap.addEventListener("pointerup", (e) => {
    if (drag && e.pointerId === drag.pointer) endDrag();
  });
  el.wallMap.addEventListener("pointercancel", (e) => {
    if (drag && e.pointerId === drag.pointer) endDrag();
  });
  el.wallMap.addEventListener("keydown", (e) => {
    const seam = e.target.closest("[data-seam]");
    if (!seam) return;
    const step = e.shiftKey ? 2 : SEAM_KEY_STEP;
    const by = { ArrowRight: step, ArrowUp: step, ArrowLeft: -step, ArrowDown: -step }[e.key];
    const axis = seam.dataset.seam;
    const index = Number(seam.dataset.index);
    if (by === undefined && e.key !== "Home") return;
    e.preventDefault();
    setSeam(axis, index, e.key === "Home" ? 0 : seamValue(axis, index) + by);
    linesUntil = Date.now() + LINES_LINGER_MS;
    wallChanged();
    el.wallMap.querySelector(`[data-seam="${axis}"][data-index="${index}"]`)?.focus();
  });

  el.wallFewer.addEventListener("click", () => {
    wall.cols = Math.max(1, wallLayout().cols - 1);
    wallChanged();
  });
  el.wallMore.addEventListener("click", () => {
    wall.cols = Math.min(wallLayout().count, wallLayout().cols + 1);
    wallChanged();
  });

  // Every seam at once, keeping how they differ from one another.
  const nudgeAll = (by) => {
    const { cols, rows } = wallLayout();
    wall.seamsX = seams("x", cols - 1).map((mm) => clampGap(mm + by));
    wall.seamsY = seams("y", rows - 1).map((mm) => clampGap(mm + by));
    wall.gap = clampGap(wall.gap + by);
    linesUntil = Date.now() + LINES_LINGER_MS;
    wallChanged();
  };
  el.wallGapLess.addEventListener("click", () => nudgeAll(-GAP_STEP));
  el.wallGapMore.addEventListener("click", () => nudgeAll(GAP_STEP));

  // Every screen shows its number at once, and the grid here shows the same
  // numbers, until pressed again.
  el.wallIdentify.addEventListener("click", () => {
    wall.identify = !wall.identify;
    changed();
    shareNow();
  });

  // Lines across the whole wall, to judge the bezels by from across the
  // room: where they bend crossing from one screen to the next, that seam
  // wants more or less.
  el.wallLines.addEventListener("click", () => {
    wall.lines = !wall.lines;
    linesUntil = 0;
    changed();
    shareNow();
  });
}

function changed() {
  renderSheet();
  document.dispatchEvent(new CustomEvent("uwu:sharechange"));
}

function wireSheet() {
  el.button.addEventListener("click", () => {
    const last = readSetting("lastCode");
    if (!el.joinInput.value && last) el.joinInput.value = last;
    el.joinNote.hidden = true;
    renderSheet();
    openModal("shareModal");
  });

  el.modeSeg.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-share-mode]");
    if (!btn) return;
    const mode = MODES.includes(btn.dataset.shareMode) ? btn.dataset.shareMode : "mirror";
    writeSetting("shareMode", mode);
    if (host) {
      // Screens already joined become the first places of a Big Screen.
      // Leaving one keeps them connected, showing the same card.
      host.maxGuests = maxGuestsFor(mode);
      if (mode === "bigscreen") {
        for (const guest of guests.values()) if (guest.screen) placeScreen(guest.screen);
      }
    }
    changed();
    // Straight away rather than on the next beat, and the deck right behind
    // the snapshot that says to expect one.
    shareNow();
    sendDeck();
  });

  el.guests.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-remove-guest]");
    if (!btn || !host) return;
    const id = (el.guests.dataset.ids || "").split(" ")[Number(btn.dataset.removeGuest)];
    if (!id) return;
    removeGuest(id);
    changed();
  });

  el.start.addEventListener("click", () => {
    status = { status: "idle" };
    startHosting({ ask: true });
  });

  el.newCode.addEventListener("click", () => restartWithFreshCode({ tellGuest: true }));

  el.stop.addEventListener("click", () => {
    stopHosting({ tellGuest: true });
    writeSetting("shareRole", null);
    // A Big Screen put together next time starts from no screens. A new
    // code, or a reload, keeps the places for the screens to come back to.
    clearWall();
    changed();
  });

  el.joinForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const code = normaliseCode(el.joinInput.value);
    if (!isValidCode(code)) {
      el.joinNote.textContent = `A code is ${CODE_LENGTH} characters, from the other device's share sheet.`;
      el.joinNote.hidden = false;
      return;
    }

    // A device is one or the other. Joining somebody else's screen ends
    // this one's sharing, and says so to its own guest.
    if (host) {
      stopHosting({ tellGuest: true });
      changed();
    }
    closeModal("shareModal");
    startViewing(code, { ask: true });
  });
}

/* `getFrame` returns what the other screen should know about, or null:
   { presenting, card, nearby: [cards whose pictures are worth sending early],
     deck: the whole deck, read only when sending it } */
export function initShare({ getFrame }) {
  frame = getFrame;

  el.button = document.getElementById("shareBtn");
  el.modeSeg = document.getElementById("shareMode");
  el.modeButtons = el.modeSeg.querySelectorAll("[data-share-mode]");
  el.modeNote = document.getElementById("shareModeNote");
  el.idle = document.getElementById("shareIdle");
  el.live = document.getElementById("shareLive");
  el.start = document.getElementById("shareStart");
  el.startNote = document.getElementById("shareStartNote");
  el.qr = document.getElementById("shareQr");
  el.code = document.getElementById("shareCode");
  el.link = document.getElementById("shareLink");
  el.status = document.getElementById("shareStatus");
  el.newCode = document.getElementById("shareNewCode");
  el.stop = document.getElementById("shareStop");
  el.joinForm = document.getElementById("joinForm");
  el.joinInput = document.getElementById("joinCode");
  el.joinNote = document.getElementById("joinNote");
  el.wall = document.getElementById("wall");
  el.wallEmpty = document.getElementById("wallEmpty");
  el.wallMap = document.getElementById("wallMap");
  el.wallHint = document.getElementById("wallHint");
  el.wallFewer = document.getElementById("wallFewer");
  el.wallCols = document.getElementById("wallCols");
  el.wallMore = document.getElementById("wallMore");
  el.wallGapLess = document.getElementById("wallGapLess");
  el.wallGap = document.getElementById("wallGap");
  el.wallGapMore = document.getElementById("wallGapMore");
  el.wallIdentify = document.getElementById("wallIdentify");
  el.wallIdentifyLabel = document.getElementById("wallIdentifyLabel");
  el.wallLines = document.getElementById("wallLines");
  el.wallLinesLabel = document.getElementById("wallLinesLabel");
  el.guests = document.getElementById("shareGuests");

  el.host = document.getElementById("shareHost");
  if (el.host) el.host.textContent = location.host;

  wireSheet();
  wireWall();
  renderSheet();

  // Sharing when the page was reloaded: back on the same code, so the other
  // screen rejoins without anybody reading it out again.
  if (readSetting("shareRole") === "host") startHosting();
}
