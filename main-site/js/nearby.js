/* Sharing with no wifi or internet, between phones that both have the Android
   app: Google's Nearby Connections, through the app (NearbyShare.java). p2p.js
   uses it beside PeerJS, so in the app a screen joins whichever way reaches
   first, and with no network at all, this way still does.

   A link here looks to p2p.js like a PeerJS DataConnection: `peer`, `open`,
   on("open" | "data" | "close"), send(message), close({ flush }), and
   `bufferSize`, which is how many of its messages are still on their way. So
   share.js and viewer.js work the same over either.

   The sharing phone advertises a tag made from the share code, not the code:
   a slow hash, so a phone nearby listening for adverts can't read the code
   off the air or work it back out. The code itself is checked by the app,
   inside Nearby's encrypted connection, before a link reaches the page.

   Nearby carries at most 32 KB a message, so longer ones (a sent deck) go in
   parts and are put back together on the other side. Snapshots, twenty a
   second, are skipped while a slow link still has a backlog: the next one
   says everything the skipped one did. Nothing else is ever skipped.

   Nothing here runs in a browser or the PWA. */

import { AppBridge } from "./app-bridge.js";

// Under Nearby's 32 KB once in UTF-8, whatever the characters.
const MAX_BYTES = 30000;
// A part of a longer message: at most 6 bytes a character once escaped.
const PART_CHARS = 5000;
const MAX_PARTS = 2000;
const MAX_PARTIAL = 4;
// Snapshots skipped while this many messages are on their way.
const BACKLOG = 6;
// A closing link waits this long at most for what it has sent to leave.
const FLUSH_MS = 1000;
const TAG_SALT = "uwuflash-nearby-1";
const TAG_ROUNDS = 100000;

const encoder = new TextEncoder();
const links = new Map(); // Nearby's endpoint id -> NearbyLink
let onLink = null; // who takes a link that opens: the host's, or the guest's
let session = 0;
let wired = false;

class NearbyLink {
  constructor(id) {
    this.id = id;
    this.peer = `nearby-${id}`;
    this.metadata = undefined;
    this.open = false;
    this.closed = false;
    this.handlers = { open: [], data: [], close: [], error: [] };
    // Sent and not yet gone: id -> whether it was a snapshot. Calls not yet
    // answered with an id are counted apart, as an id can be reported gone
    // before its call is answered.
    this.inFlight = new Map();
    this.asking = { all: 0, snapshots: 0 };
    this.early = new Set();
    this.partial = new Map();
    this.next = 0;
  }

  on(event, fn) {
    this.handlers[event]?.push(fn);
  }

  emit(event, arg) {
    for (const fn of this.handlers[event] || []) fn(arg);
  }

  // What share.js waits on before the next chunk of a picture: anything but
  // snapshots, which never hold a picture up.
  get bufferSize() {
    let count = this.asking.all - this.asking.snapshots;
    for (const snapshot of this.inFlight.values()) if (!snapshot) count++;
    return count;
  }

  get backlog() {
    return this.asking.all + this.inFlight.size;
  }

  send(message) {
    if (!this.open) return;
    const snapshot = message?.type === "state";
    if (snapshot && this.backlog >= BACKLOG) return;
    let text;
    try {
      text = JSON.stringify(message);
    } catch {
      return;
    }
    if (encoder.encode(text).length <= MAX_BYTES) {
      this.push(text, snapshot);
      return;
    }
    const parts = split(text);
    if (parts.length > MAX_PARTS) return;
    const id = (this.next++).toString(36);
    parts.forEach((s, i) => this.push(JSON.stringify({ "~": "part", id, i, n: parts.length, s }), false));
  }

  push(text, snapshot) {
    this.asking.all++;
    if (snapshot) this.asking.snapshots++;
    const answered = () => {
      this.asking.all--;
      if (snapshot) this.asking.snapshots--;
    };
    AppBridge.call("Flash", "nearbySend", { link: this.id, data: text }).then(
      ({ id }) => {
        answered();
        if (this.early.delete(id)) return;
        if (!this.closed) this.inFlight.set(id, snapshot);
      },
      answered
    );
  }

  // The app says a message has gone, or failed.
  sent(id) {
    if (this.inFlight.delete(id)) return;
    this.early.add(id);
    if (this.early.size > 64) this.early.delete(this.early.values().next().value);
  }

  received(data) {
    let message;
    try {
      message = JSON.parse(data);
    } catch {
      return;
    }
    if (message?.["~"] !== "part") {
      this.emit("data", message);
      return;
    }
    const { id, i, n, s } = message;
    if (
      typeof id !== "string" || id.length > 12 ||
      !Number.isInteger(n) || n < 1 || n > MAX_PARTS ||
      !Number.isInteger(i) || i < 0 || i >= n ||
      typeof s !== "string" || s.length > PART_CHARS
    ) {
      return;
    }
    let entry = this.partial.get(id);
    if (!entry || entry.n !== n) {
      entry = { n, parts: new Array(n), count: 0 };
      this.partial.set(id, entry);
      // Bounded, so a phone that starts long messages and never finishes them
      // can't fill this one's memory.
      while (this.partial.size > MAX_PARTIAL) this.partial.delete(this.partial.keys().next().value);
    }
    if (entry.parts[i] === undefined) {
      entry.parts[i] = s;
      entry.count++;
    }
    if (entry.count < n) return;
    this.partial.delete(id);
    try {
      this.emit("data", JSON.parse(entry.parts.join("")));
    } catch {
      // Not one message after all: dropped, as any unreadable one is.
    }
  }

  opened() {
    this.open = true;
    this.emit("open");
  }

  close({ flush = false } = {}) {
    if (this.closed) return;
    this.closed = true;
    const go = () => {
      this.open = false;
      links.delete(this.id);
      AppBridge.call("Flash", "nearbyClose", { link: this.id }).catch(() => {});
      this.emit("close");
    };
    if (!flush || this.backlog === 0) {
      go();
      return;
    }
    const until = Date.now() + FLUSH_MS;
    const wait = () => (this.backlog === 0 || Date.now() > until ? go() : setTimeout(wait, 50));
    wait();
  }

  // The app says it has gone.
  ended() {
    if (this.closed) return;
    this.closed = true;
    this.open = false;
    links.delete(this.id);
    this.emit("close");
  }
}

// Never between the two halves of a character outside the basic plane.
function split(text) {
  const parts = [];
  for (let at = 0; at < text.length; ) {
    let end = Math.min(at + PART_CHARS, text.length);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end--;
    parts.push(text.slice(at, end));
    at = end;
  }
  return parts;
}

function wire() {
  if (wired) return;
  wired = true;
  const valid = (link) => typeof link === "string" && /^[A-Za-z0-9]{1,16}$/.test(link);
  AppBridge.listen("Flash", "nearbyOpen", ({ link }) => {
    if (!valid(link) || links.has(link)) return;
    const l = new NearbyLink(link);
    links.set(link, l);
    if (!onLink) {
      l.close();
      return;
    }
    // Handed over first, so its owner is listening when it says it's open.
    onLink(l);
    l.opened();
  });
  AppBridge.listen("Flash", "nearbyData", ({ link, data }) => {
    if (typeof data === "string") links.get(link)?.received(data);
  });
  AppBridge.listen("Flash", "nearbyClosed", ({ link }) => links.get(link)?.ended());
  AppBridge.listen("Flash", "nearbySent", ({ link, id }) => {
    if (typeof id === "string") links.get(link)?.sent(id);
  });
}

// The advertised name's tag: PBKDF2 of the code, 64 bits, as 16 hex digits.
async function tagFor(code) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(code), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", hash: "SHA-256", salt: encoder.encode(TAG_SALT), iterations: TAG_ROUNDS },
    key,
    64
  );
  return [...new Uint8Array(bits)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/* Whether this phone can share this way: in the app, with Play services. */
export async function nearbyAvailable() {
  if (!AppBridge.native) return false;
  await AppBridge.ready(2000);
  return AppBridge.has("nearby");
}

/* Starting one side, the host's ("nearbyHost") or a screen's ("nearbyJoin").
   `ask` lets the app ask for its permissions, which only a button press
   should. Answers { state, message, stop() }, state as FlashPlugin.java says;
   stop() ends this session, and nothing if another has started since. */
async function begin(method, code, { ask = false, onLink: take }) {
  const mine = ++session;
  wire();
  onLink = take;
  const stop = () => {
    if (session !== mine) return;
    session++;
    onLink = null;
    for (const link of [...links.values()]) link.close();
    AppBridge.call("Flash", method === "nearbyHost" ? "nearbyStop" : "nearbyLeave").catch(() => {});
  };
  let answer;
  try {
    answer = await AppBridge.call("Flash", method, { code, tag: await tagFor(code), ask });
  } catch {
    answer = { state: "failed" };
  }
  return { state: answer?.state || "failed", message: answer?.message || "", stop };
}

/* Advertising a share. Each screen that joins this way and sends the right
   code reaches `onLink` as a link, before it says it's open. */
export function nearbyHost(code, options) {
  return begin("nearbyHost", code, options);
}

/* Looking for a share, and connecting once found. The link reaches `onLink`
   before it says it's open. */
export function nearbyJoin(code, options) {
  return begin("nearbyJoin", code, options);
}
