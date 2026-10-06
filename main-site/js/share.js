/* Sharing the cards with another screen: the host's side, and the share
   sheet that starts either side. See STUN-p2p-spec.md at the repo root.

   This device is the host. It holds the deck and publishes a code; the other
   screen joins as the guest. The guest shows nothing until this device
   presses play, then shows the presented card full screen, and goes back to
   waiting when the presenter closes. Cards being edited never leave this
   device; only a card being presented does.

   Three ways to share, picked in the sheet:

   Mirror  both screens show the card.
   Extend  the other screen shows the card and this one becomes a presenter
           view: the same card smaller, with the next one beneath it.
   Send    nothing is shown. The other device is sent the whole deck, hidden
           layers and pictures included, and can add it to its own cards or
           replace its own with it. The one time the deck leaves this device,
           and only because somebody picked it.

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
} from "./p2p.js";
import { qrSvg } from "./qr.js";
import { getImage, readSetting, writeSetting } from "./store.js";
import { closeModal, openModal, toast } from "./ui.js";
import { startViewing } from "./viewer.js";

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

const MODE_NOTES = {
  mirror: "Both screens show the card.",
  extend: "The other screen shows the card. This one shows it smaller, with the next card beneath it.",
  send: "The other device gets a copy of all your cards, pictures included, to add to its own or to replace them.",
};

let frame = () => null;
let host = null;
let status = { status: "idle" };
let retriedTaken = false;
let beatTimer = null;
let shownCode = "";

const lastHeard = new Map(); // guest peer id -> last time anything arrived
let guestImages = new Set(); // image ids the guest says it holds
let offered = new Set(); // image ids sent to this guest and not yet confirmed
let pumping = false;
const prepared = new Map(); // image id -> Promise<{ mime, data }>

const el = {};

/* ---- what the rest of the app reads ---- */

export function shareMode() {
  const mode = readSetting("shareMode");
  return mode === "extend" || mode === "send" ? mode : "mirror";
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
  host.send(snapshot());
  pumpImages();
}

/* The deck was edited and saved. A guest about to copy it gets the edit,
   rather than whatever the deck was when it joined. */
export function shareDeckChanged() {
  sendDeck();
  pumpImages();
}

/* ---- hosting ---- */

async function startHosting() {
  if (host) return;

  const stored = readSetting("hostCode");
  const code = isValidCode(stored) ? stored : generateCode();
  writeSetting("hostCode", code);
  writeSetting("shareRole", "host");

  const h = new Host({ maxGuests: 1 });
  host = h;
  status = { status: "connecting" };
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
    // pictures until it says otherwise.
    lastHeard.set(detail.id, Date.now());
    guestImages = new Set();
    offered = new Set();
  });

  h.addEventListener("leave", ({ detail }) => lastHeard.delete(detail.id));

  h.addEventListener("message", ({ detail: { message, from } }) => {
    if (host === h) onMessage(message, from);
  });

  beatTimer = setInterval(beat, SNAPSHOT_MS);
  changed();

  try {
    await h.start(code);
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
  lastHeard.clear();
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
  lastHeard.set(from, Date.now());

  switch (message.type) {
    case "hello":
      if (message.v !== PROTOCOL_VERSION) {
        host.send({ type: "outdated" }, from);
        return;
      }
      host.send(snapshot(), from);
      sendDeck(from);
      break;
    case "imported":
      toast("The other device copied your cards.");
      break;
    case "have":
      guestImages = readImageList(message.images);
      guestImages.forEach((id) => offered.delete(id));
      pumpImages();
      break;
    case "bye":
      // Left on purpose, so the code is spent: one shown to a room in this
      // session should not keep working in the next.
      restartWithFreshCode();
      break;
    default:
      // `ping`, and anything from a newer build. Never thrown on.
      break;
  }
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
  for (const [id, link] of [...host.links]) {
    if (now - (lastHeard.get(id) ?? now) > GUEST_SILENT_MS) {
      lastHeard.delete(id);
      host.drop(link);
      host.refreshStatus();
    }
  }

  if (host.links.size === 0) return;
  host.send(snapshot());
  pumpImages();
}

/* ---- the snapshot ---- */

function snapshot() {
  const f = frame();
  const root = document.documentElement;
  const sending = shareMode() === "send";
  const message = {
    type: "state",
    mode: sending ? "send" : "show",
    presenting: false,
    theme: { color: root.getAttribute("data-color-theme"), mode: root.getAttribute("data-mode") },
  };

  // Nothing about the card until play is pressed: the other screen waits,
  // and what is being edited stays on this one. Sending shows nothing at
  // all; the deck goes separately, in sendDeck().
  if (!sending && f?.presenting && f.card) {
    message.presenting = true;
    message.card = wireCard(f.card);
  }

  return message;
}

// Only what drawing needs. Hidden layers are left behind rather than sent
// with a flag, since the other screen has no use for them.
function wireCard(card) {
  return {
    layout: card.layout,
    layers: card.layers
      .filter((layer) => !layer.hidden)
      .map((layer) =>
        layer.type === "image"
          ? { type: "image", imageId: layer.imageId, fit: layer.fit }
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
        ? { type: "image", imageId: layer.imageId, fit: layer.fit, hidden: layer.hidden }
        : { type: "text", text: layer.text, size: layer.size, align: layer.align, hidden: layer.hidden }
    ),
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

async function pumpImages() {
  if (pumping || !host) return;
  const h = host;
  const link = h.links.values().next().value;
  if (!link) return;

  const id = wantedImages().find((imageId) => !guestImages.has(imageId) && !offered.has(imageId));
  if (!id) return;

  pumping = true;
  offered.add(id);
  const session = offered;
  const current = () => host === h && h.links.get(link.peer) === link && offered === session;

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

function statusText() {
  switch (status.status) {
    case "connecting":
      return "Starting...";
    case "waiting":
      return "Waiting for the other screen to join.";
    case "connected":
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
    const mode = btn.dataset.shareMode;
    writeSetting("shareMode", mode === "extend" || mode === "send" ? mode : "mirror");
    changed();
    // Straight away rather than on the next beat, and the deck right behind
    // the snapshot that says to expect one.
    shareNow();
    sendDeck();
  });

  el.start.addEventListener("click", () => {
    status = { status: "idle" };
    startHosting();
  });

  el.newCode.addEventListener("click", () => restartWithFreshCode({ tellGuest: true }));

  el.stop.addEventListener("click", () => {
    stopHosting({ tellGuest: true });
    writeSetting("shareRole", null);
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
    startViewing(code);
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

  el.host = document.getElementById("shareHost");
  if (el.host) el.host.textContent = location.host;

  wireSheet();
  renderSheet();

  // Sharing when the page was reloaded: back on the same code, so the other
  // screen rejoins without anybody reading it out again.
  if (readSetting("shareRole") === "host") startHosting();
}
