/* The deck model: a stack of cards, each card a list of layers.

   A layer is either text or an image. Layers are ordered back to front, so
   the last entry in the array draws on top, the way a layers panel in
   PowerPoint or Photoshop reads from the top down. The list in the UI is
   therefore rendered reversed; the array order is the drawing order and the
   only order stored.

   That order is also what puts text above or below the image on a stacked
   layout. The layout only chooses stacked or side by side. */

export const LAYOUTS = [
  { id: "image-center", label: "Image centre" },
  { id: "image-left", label: "Image left of text" },
  { id: "image-right", label: "Image right of text" },
];

export const DEFAULT_LAYOUT = "image-center";

export const TEXT_SIZES = [
  { id: "s", label: "Small" },
  { id: "m", label: "Medium" },
  { id: "l", label: "Large" },
  { id: "xl", label: "Huge" },
];

function id() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export function makeTextLayer(text = "") {
  return { id: id(), type: "text", text, size: "l", align: "center", hidden: false };
}

export function makeImageLayer(imageId) {
  return { id: id(), type: "image", imageId, fit: "contain", hidden: false };
}

export function makeCard(text = "") {
  return {
    id: id(),
    layout: DEFAULT_LAYOUT,
    layers: [makeTextLayer(text)],
  };
}

export function makeDeck() {
  return { version: 1, cards: [makeCard("")] };
}

/* A deck read back from storage was written by an older build as easily as
   by this one. Fill in anything missing rather than trusting the shape. */
export function normaliseDeck(raw) {
  if (!raw || !Array.isArray(raw.cards) || raw.cards.length === 0) return makeDeck();

  const cards = raw.cards.map((card) => {
    const layers = Array.isArray(card?.layers)
      ? card.layers.map(normaliseLayer).filter(Boolean)
      : [];

    return {
      id: card?.id || id(),
      layout: LAYOUTS.some((l) => l.id === card?.layout) ? card.layout : DEFAULT_LAYOUT,
      // "image-between" was a layout that split the text around the image.
      // The stack does that now, so a card saved under it keeps its look by
      // moving the image to where that split used to fall.
      layers: card?.layout === "image-between" ? splitTextAroundImages(layers) : layers,
    };
  });

  return { version: 1, cards };
}

/* The old image-between rendering: half the text, then every image, then the
   rest. Written into the layer order so it survives as an ordinary card. */
function splitTextAroundImages(layers) {
  const images = layers.filter((l) => l.type === "image");
  if (images.length === 0) return layers;

  const texts = layers.filter((l) => l.type === "text");
  const half = Math.ceil(texts.length / 2);
  return [...texts.slice(0, half), ...images, ...texts.slice(half)];
}

function normaliseLayer(layer) {
  if (!layer || typeof layer !== "object") return null;

  if (layer.type === "image") {
    if (!layer.imageId) return null;
    return {
      id: layer.id || id(),
      type: "image",
      imageId: layer.imageId,
      fit: layer.fit === "cover" ? "cover" : "contain",
      hidden: layer.hidden === true,
    };
  }

  return {
    id: layer.id || id(),
    type: "text",
    text: typeof layer.text === "string" ? layer.text : "",
    size: TEXT_SIZES.some((s) => s.id === layer.size) ? layer.size : "l",
    align: ["left", "center", "right"].includes(layer.align) ? layer.align : "center",
    hidden: layer.hidden === true,
  };
}

/* Every image id the deck still refers to. What pruneImages() is given, so
   a blob is only dropped once no card points at it. */
export function referencedImageIds(deck) {
  const ids = [];
  deck.cards.forEach((card) => {
    card.layers.forEach((layer) => {
      if (layer.type === "image" && layer.imageId) ids.push(layer.imageId);
    });
  });
  return ids;
}

/* Move an item within an array, in place. Used by the layer list and by the
   card strip, which reorder the same way. */
export function move(list, from, to) {
  if (from === to) return false;
  if (from < 0 || from >= list.length) return false;
  if (to < 0 || to >= list.length) return false;
  const [item] = list.splice(from, 1);
  list.splice(to, 0, item);
  return true;
}

/* The text a card is summarised by in the card strip and the deck list. */
export function cardSummary(card) {
  const text = card.layers
    .filter((l) => l.type === "text" && l.text.trim())
    .map((l) => l.text.trim())
    .join(" ");

  if (text) return text.length > 40 ? `${text.slice(0, 40)}...` : text;
  return card.layers.some((l) => l.type === "image") ? "Image" : "Empty card";
}
