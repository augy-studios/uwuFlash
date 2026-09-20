/* Drawing a card. One renderer, used by both the editor preview and the
   fullscreen presenter, so what somebody arranges is exactly what the room
   sees. The only difference between the two is the size of the box it is
   given, which is why every size here is in cqw/cqh against a container
   query rather than in px. */

import { imageUrl } from "./store.js";
import { escapeHtml } from "./ui.js";

const SIZE_CLASS = { s: "size-s", m: "size-m", l: "size-l", xl: "size-xl" };

/* The layout decides how the layers are grouped into slots, not what is in
   them. Text layers fill the text slots in order; image layers fill the
   image slot in order. A card with no image renders as text alone whatever
   its layout says, so switching layouts never blanks a card. */
function groupLayers(card) {
  const visible = card.layers.filter((l) => !l.hidden);
  const texts = visible.filter((l) => l.type === "text");
  const images = visible.filter((l) => l.type === "image");

  if (card.layout === "image-between") {
    // Text above, image, then the rest of the text below. With one text
    // layer there is nothing to put underneath, which reads as image-center.
    const half = Math.ceil(texts.length / 2);
    return [
      { kind: "text", layers: texts.slice(0, half) },
      { kind: "image", layers: images },
      { kind: "text", layers: texts.slice(half) },
    ];
  }

  const textSlot = { kind: "text", layers: texts };
  const imageSlot = { kind: "image", layers: images };

  if (card.layout === "image-left") return [imageSlot, textSlot];
  if (card.layout === "image-right") return [textSlot, imageSlot];

  // image-center: image first, text under it.
  return [imageSlot, textSlot];
}

function textLayerHtml(layer) {
  const cls = SIZE_CLASS[layer.size] || SIZE_CLASS.l;
  // Blank layers still take part in the layout while editing, so somebody
  // adding a line does not watch the card jump when they type the first
  // character. The placeholder is never shown when presenting.
  const body = layer.text.trim()
    ? escapeHtml(layer.text).replace(/\n/g, "<br>")
    : '<span class="card-text-empty">Text</span>';

  return `<p class="card-text ${cls} align-${layer.align}">${body}</p>`;
}

function imageLayerHtml(layer, url) {
  if (!url) return '<div class="card-image-missing">Image unavailable</div>';
  return `<img class="card-image fit-${layer.fit}" src="${url}" alt="">`;
}

/* Async because image blobs come out of IndexedDB. The caller awaits it
   before swapping the markup in, so a card never paints its text first and
   its picture a frame later. */
export async function renderCard(card, target, { presenting = false } = {}) {
  const slots = groupLayers(card);

  const urls = new Map();
  await Promise.all(
    slots
      .filter((s) => s.kind === "image")
      .flatMap((s) => s.layers)
      .map(async (layer) => {
        urls.set(layer.id, await imageUrl(layer.imageId));
      })
  );

  const html = slots
    .filter((slot) => slot.layers.length > 0)
    .map((slot) => {
      const inner = slot.layers
        .map((layer) =>
          slot.kind === "image"
            ? imageLayerHtml(layer, urls.get(layer.id))
            : textLayerHtml(layer)
        )
        .join("");
      return `<div class="card-slot slot-${slot.kind}">${inner}</div>`;
    })
    .join("");

  target.className = `card-canvas layout-${card.layout}${presenting ? " presenting" : ""}`;
  target.innerHTML = html || '<div class="card-empty">This card is empty</div>';
}
