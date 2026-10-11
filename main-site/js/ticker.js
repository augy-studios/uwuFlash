/* A card's words as a news ticker: every line of text on the card, run
   together onto one line that rolls right to left, round and round.

   Drawn in the same box as the card, so on a Big Screen the line is as wide
   as the whole wall and runs from one screen onto the next behind the
   bezels. Every screen works out where the line is from the same clock, the
   host's, so the screens agree on it without being sent a frame of it. A
   picture filling the card stays behind the line; any other picture is left
   out, since the line has nowhere to put it.

   Where the line is depends only on the time and how many letters it has,
   never on how wide it measures, which differs a hair between two devices
   and would otherwise pull them apart a little more on every lap. */

import { escapeHtml } from "./ui.js";
import { fillImage } from "./deck.js";

// Letters a second, roughly, in em, for each of deck.js's TICKER_SPEED_IDS.
export const TICKER_SPEEDS = { slow: 1.5, normal: 3, fast: 5 };
const LETTER_EM = 0.55; // a rough width of one letter, in em
const GAP = "   •   ";
const SIZE_CLASS = { s: "size-s", m: "size-m", l: "size-l", xl: "size-xl" };
const ORDER = ["s", "m", "l", "xl"];

// Ticker elements on screen -> { now: () => ms on the shared clock, period: ms a lap }
const running = new Map();
let raf = 0;

export function tickerText(card) {
  return card.layers
    .filter((l) => l.type === "text" && !l.hidden && l.text.trim())
    .map((l) => l.text.replace(/\s+/g, " ").trim())
    .join(GAP);
}

export function hasTickerText(card) {
  return tickerText(card) !== "";
}

// Whether a card is drawn as a ticker: its own switch is on and it has
// words to roll. A card with only a picture is drawn as a card.
export function showsTicker(card) {
  return card?.ticker === true && hasTickerText(card);
}

/* `now` is the clock every screen agrees on, in milliseconds; `speed` is a
   key of TICKER_SPEEDS. Draws into `target` the way renderCard() does. */
export async function renderTicker(card, target, { resolveImage, now = Date.now, speed = "normal" } = {}) {
  const text = tickerText(card) + GAP;
  const fill = fillImage(card);
  const url = fill ? await resolveImage(fill.imageId) : null;
  const biggest = card.layers
    .filter((l) => l.type === "text" && !l.hidden)
    .reduce((size, l) => (ORDER.indexOf(l.size) > ORDER.indexOf(size) ? l.size : size), "s");

  const background = !fill
    ? ""
    : url
      ? `<img class="card-fill" src="${url}" alt="" style="object-position: ${Number(fill.focus?.x ?? 50)}% ${Number(fill.focus?.y ?? 50)}%" draggable="false">`
      : '<div class="card-fill card-fill-missing"></div>';

  target.className = `card-canvas presenting ticker-canvas${fill ? " filled" : ""}`;
  target.innerHTML = `${background}<div class="ticker ${SIZE_CLASS[biggest]}" role="marquee" aria-label="${escapeHtml(tickerText(card))}">
    <div class="ticker-track" aria-hidden="true"><span class="ticker-run">${escapeHtml(text)}</span></div>
  </div>`;

  const ticker = target.querySelector(".ticker");
  const perSecond = TICKER_SPEEDS[speed] ?? TICKER_SPEEDS.normal;
  running.set(ticker, { now, period: (Math.max(1, [...text].length) * LETTER_EM * 1000) / perSecond });
  if (!raf) raf = requestAnimationFrame(frame);
}

function frame() {
  raf = 0;
  for (const [ticker, { now, period }] of running) {
    if (!ticker.isConnected) {
      running.delete(ticker);
      continue;
    }
    place(ticker, ((now() % period) + period) % period / period);
  }
  if (running.size) raf = requestAnimationFrame(frame);
}

// `lap` is how far through one lap the line is, 0 to 1.
function place(ticker, lap) {
  const track = ticker.firstElementChild;
  const run = track.firstElementChild;
  const width = run.offsetWidth;
  if (!width) return;

  // Enough copies of the line to cover the box with one to spare, so the
  // end of one lap is always followed on screen by the start of the next.
  const copies = Math.ceil(ticker.clientWidth / width) + 1;
  while (track.children.length < copies) track.appendChild(run.cloneNode(true));
  while (track.children.length > copies) track.lastElementChild.remove();

  // Reduced motion still rolls, since a ticker that stood still would only
  // ever show its first words, but in whole steps rather than a glide.
  const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  const at = reduce ? Math.floor(lap * 8) / 8 : lap;
  track.style.transform = `translate3d(${(-at * width).toFixed(2)}px, 0, 0)`;
}
