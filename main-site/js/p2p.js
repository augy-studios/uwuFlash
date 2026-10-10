/* Host and guest pairing over PeerJS, STUN only. See STUN-p2p-spec.md at the
   repo root, which this follows; the reference implementation there is where
   this module started.

   The host is the device with the cards. The guest is the other screen. A
   free public broker introduces the two, and after that nothing passes
   through a server: no TURN relay, no backend, no account. The cost, stated
   in the spec, is that both devices have to be able to reach each other
   directly, which in practice means the same wifi or a hotspot. */

const PEERJS_URL = "https://cdnjs.cloudflare.com/ajax/libs/peerjs/1.5.4/peerjs.min.js";
const PEER_PREFIX = "uwuflash-";
const CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXYZ23456789";
export const CODE_LENGTH = 6;
// 2 added sending the deck. A guest on 1 would sit on "Ready" forever when
// the host picked Send, so the two are told to reload instead. 3 added Big
// Screen, where a guest on 2 would show the whole card instead of its piece.
// 4 added a picture filling the card, which a guest on 3 would draw in its
// own space beside the words, uncropped.
export const PROTOCOL_VERSION = 4;
// The most pictures either side keeps track of for the other: the guest's
// `have` list, and the pictures a sent deck may bring.
export const MAX_SHARED_IMAGES = 200;
// The most screens one Big Screen takes. Each is sent its own snapshot twenty
// times a second, a few hundred bytes apiece, and twelve is a wall of phones
// four across and three down.
export const MAX_SCREENS = 12;
const CONNECT_TIMEOUT_MS = 15000;

// STUN only. Supplying `config` replaces PeerJS's default, which includes a
// public TURN relay. Every `new Peer` in the app goes through this object.
const ICE_SERVERS = [
  { urls: "stun:stun.l.google.com:19302" },
  { urls: "stun:stun.cloudflare.com:3478" },
];
const PEER_OPTIONS = { debug: 0, config: { iceServers: ICE_SERVERS } };

const BROKER_ERRORS = new Set([
  "network", "server-error", "socket-error", "socket-closed", "disconnected",
]);

/* ---- codes ---- */

export function generateCode() {
  // Bytes at or above this would make some characters likelier than others.
  const limit = 256 - (256 % CODE_ALPHABET.length);
  let code = "";
  while (code.length < CODE_LENGTH) {
    const [byte] = crypto.getRandomValues(new Uint8Array(1));
    if (byte < limit) code += CODE_ALPHABET[byte % CODE_ALPHABET.length];
  }
  return code;
}

export function normaliseCode(input) {
  return String(input || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, CODE_LENGTH);
}

export function isValidCode(input) {
  const code = normaliseCode(input);
  return code.length === CODE_LENGTH && [...code].every((c) => CODE_ALPHABET.includes(c));
}

/* ---- library ----

   Loaded on demand, never at boot. Sharing is the one part of the app that
   needs the network, so it is the one part that must not stop the app
   starting. The service worker deliberately does not cache this. */

let peerLibrary = null;

function loadPeerJs() {
  if (peerLibrary) return Promise.resolve(peerLibrary);
  if (window.Peer) return Promise.resolve((peerLibrary = window.Peer));

  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = PEERJS_URL;
    script.async = true;
    script.onload = () =>
      window.Peer ? resolve((peerLibrary = window.Peer)) : reject(new Error("PeerJS did not define Peer"));
    script.onerror = () => {
      // Removed so a later attempt, back online, adds a fresh tag.
      script.remove();
      reject(new Error("Could not load PeerJS"));
    };
    document.head.appendChild(script);
  });
}

export function describePeerError(error) {
  switch (error?.type) {
    case "peer-unavailable":
      return "Nobody is sharing with that code. Check it and try again.";
    case "unavailable-id":
      return "That code is already in use. Generate a new one.";
    case "network":
    case "server-error":
    case "socket-error":
    case "socket-closed":
      return "Cannot reach the pairing service. Everything else still works.";
    case "browser-incompatible":
      return "This browser cannot make peer-to-peer connections.";
    default:
      return "The connection failed.";
  }
}

/* ---- shared ---- */

class Connection extends EventTarget {
  constructor() {
    super();
    this.peer = null;
    this.status = "idle";
  }

  setStatus(status, detail = {}) {
    this.status = status;
    this.dispatchEvent(new CustomEvent("status", { detail: { status, ...detail } }));
  }

  bindLink(link) {
    // A link that closes without ever opening never reached the other device.
    let everOpened = false;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      this.onLinkClosed(link, everOpened);
    };

    link.on("open", () => {
      everOpened = true;
      this.onLinkOpen(link);
    });
    link.on("data", (message) => {
      if (!message || typeof message !== "object" || typeof message.type !== "string") return;
      this.dispatchEvent(new CustomEvent("message", { detail: { message, from: link.peer } }));
    });
    link.on("close", finish);
    link.on("error", finish);
  }

  // The broker socket can drop while channels stay up. Re-register under the
  // same id, backing off while it keeps failing.
  watchBroker() {
    const peer = this.peer;
    let delay = 1000;
    peer.on("open", () => { delay = 1000; });
    peer.on("disconnected", () => {
      setTimeout(() => {
        if (this.peer === peer && !peer.destroyed && peer.disconnected) peer.reconnect();
      }, delay);
      delay = Math.min(delay * 2, 30000);
    });
  }

  destroyPeer() {
    // Cleared first, so the disconnect that destroy() causes is not retried.
    const peer = this.peer;
    this.peer = null;
    peer?.destroy();
  }
}

/* ---- host ---- */

export class Host extends Connection {
  constructor({ maxGuests = 1 } = {}) {
    super();
    this.maxGuests = maxGuests;
    this.links = new Map(); // guest peer id -> open link
  }

  async start(code) {
    const Peer = await loadPeerJs();
    this.code = code;
    this.setStatus("connecting");

    this.peer = new Peer(PEER_PREFIX + code, PEER_OPTIONS);
    this.watchBroker();

    this.peer.on("open", () => this.refreshStatus());
    this.peer.on("connection", (link) => {
      if (this.maxGuests === 1) {
        // The newcomer replaces the incumbent.
        for (const old of [...this.links.values()]) this.drop(old);
      } else if (this.links.size >= this.maxGuests) {
        link.on("open", () => {
          link.send({ type: "full" });
          link.close({ flush: true });
        });
        return;
      }
      this.bindLink(link);
    });
    this.peer.on("error", (error) => {
      if (error?.type === "unavailable-id") {
        this.setStatus("error", { message: describePeerError(error), taken: true });
        return;
      }
      // Guests already attached do not need the broker.
      if (this.links.size > 0 && BROKER_ERRORS.has(error?.type)) return;
      this.setStatus("error", { message: describePeerError(error) });
    });
  }

  onLinkOpen(link) {
    this.links.set(link.peer, link);
    this.dispatchEvent(new CustomEvent("join", { detail: { id: link.peer, metadata: link.metadata } }));
    this.refreshStatus();
  }

  onLinkClosed(link) {
    // Links this end dropped, and links that never opened, are not in the map.
    if (this.links.get(link.peer) !== link) return;
    this.links.delete(link.peer);
    this.dispatchEvent(new CustomEvent("leave", { detail: { id: link.peer } }));
    this.refreshStatus();
  }

  // A guest that dropped and one that never came look the same from here.
  refreshStatus() {
    this.setStatus(this.links.size > 0 ? "connected" : "waiting");
  }

  // Removed before closing: close() emits "close" synchronously.
  drop(link) {
    this.links.delete(link.peer);
    link.close();
  }

  // To one guest when `to` is given, otherwise to all of them.
  send(message, to) {
    for (const [id, link] of this.links) {
      if (to && id !== to) continue;
      try {
        link.send(message);
      } catch {
        // Closed between the check and the send; its close handler reports it.
      }
    }
  }

  close() {
    for (const link of [...this.links.values()]) this.drop(link);
    this.destroyPeer();
    this.setStatus("idle");
  }
}

/* ---- guest ---- */

export class Guest extends Connection {
  // `introduce` returns what goes in `hello` beside the version: asked at the
  // moment the link opens, so it describes the screen as it is then.
  constructor({ introduce = () => ({}) } = {}) {
    super();
    this.link = null;
    this.timer = null;
    this.introduce = introduce;
  }

  async connect(code, metadata) {
    const Peer = await loadPeerJs();
    this.setStatus("connecting");

    this.peer = new Peer(PEER_OPTIONS);
    this.watchBroker();

    // Nothing errors when ICE cannot find a path; it just keeps trying.
    this.timer = setTimeout(() => {
      if (this.status !== "connecting") return;
      this.hangUp();
      this.setStatus("unreachable");
    }, CONNECT_TIMEOUT_MS);

    // once, not on: a broker reconnect fires "open" again.
    this.peer.once("open", () => {
      this.link = this.peer.connect(PEER_PREFIX + code, { reliable: true, metadata });
      this.bindLink(this.link);
    });
    this.peer.on("error", (error) => {
      if (this.status === "connected" && BROKER_ERRORS.has(error?.type)) return;
      this.hangUp();
      this.setStatus("error", { message: describePeerError(error), type: error?.type });
    });
  }

  onLinkOpen(link) {
    if (link !== this.link) return;
    clearTimeout(this.timer);
    this.setStatus("connected");
    this.send({ ...this.introduce(), type: "hello", v: PROTOCOL_VERSION });
  }

  onLinkClosed(link, everOpened) {
    if (link !== this.link) return;
    this.link = null;
    this.setStatus(everOpened ? "dropped" : "unreachable");
  }

  send(message) {
    if (!this.link?.open) return;
    try {
      this.link.send(message);
    } catch {
      // As on the host.
    }
  }

  // Leaving on purpose: `bye` first, and a flushed close so it arrives.
  leave() {
    this.send({ type: "bye" });
    clearTimeout(this.timer);
    const link = this.link;
    const peer = this.peer;
    this.link = null;
    this.peer = null;
    link?.close({ flush: true });
    setTimeout(() => peer?.destroy(), 1000);
    this.setStatus("idle");
  }

  hangUp() {
    clearTimeout(this.timer);
    const link = this.link;
    this.link = null;
    link?.close();
    this.destroyPeer();
  }

  close() {
    this.hangUp();
    this.setStatus("idle");
  }
}
