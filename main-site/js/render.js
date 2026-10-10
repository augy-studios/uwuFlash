/* Drawing a card. One renderer, used by both the editor preview and the
   fullscreen presenter, so what somebody arranges is exactly what the room
   sees. The only difference between the two is the size of the box it is
   given, which is why every size here is in cqw/cqh against a container
   query rather than in px. */

import { imageUrl } from "./store.js";
import { escapeHtml } from "./ui.js";
import { fillImage } from "./deck.js";

const SIZE_CLASS = { s: "size-s", m: "size-m", l: "size-l", xl: "size-xl" };

/* The layout decides whether the image sits beside the text or stacked with
   it. Where in the stack is the layer order's business: text layers before
   the image in the array draw above it, text layers after it draw below. A
   card with no image renders as text alone whatever its layout says, so
   switching layouts never blanks a card. */
function groupLayers(card) {
  const visible = card.layers.filter((l) => !l.hidden);

  // A picture filling the card is drawn behind it, not in a slot, so the
  // words lay out as on a card with no picture at all.
  if (fillImage(card)) return [{ kind: "text", layers: visible.filter((l) => l.type === "text") }];
  const images = visible.filter((l) => l.type === "image");

  if (images.length === 0) return [{ kind: "text", layers: visible }];

  const imageSlot = { kind: "image", layers: images };

  if (card.layout === "image-between") {
    // The one layout that places the image itself: text is split down the
    // middle and the image goes in the gap, wherever the layers sit in the
    // array. The arrows still order the text within each half. With one
    // text layer there is nothing to put underneath, which reads as
    // image-center.
    const texts = visible.filter((l) => l.type === "text");
    const half = Math.ceil(texts.length / 2);
    return [
      { kind: "text", layers: texts.slice(0, half) },
      imageSlot,
      { kind: "text", layers: texts.slice(half) },
    ];
  }

  if (card.layout === "image-left" || card.layout === "image-right") {
    // Side by side, so there is no above or below to honour; the layer
    // order only decides the order of the text within its own column.
    const textSlot = { kind: "text", layers: visible.filter((l) => l.type === "text") };
    return card.layout === "image-left" ? [imageSlot, textSlot] : [textSlot, imageSlot];
  }

  // image-center. Split the text on the image's position in the array, so
  // the layer arrows move the picture up and down the card. Several images
  // are drawn as one block at the first one's place, which is where the
  // arrows put the group anyway.
  const first = visible.indexOf(images[0]);
  const last = visible.indexOf(images[images.length - 1]);

  return [
    { kind: "text", layers: visible.slice(0, first) },
    imageSlot,
    { kind: "text", layers: visible.slice(last + 1).filter((l) => l.type === "text") },
  ];
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

// Number() rather than the value as given: it lands in an attribute.
function focusStyle(layer) {
  const x = Number(layer.focus?.x ?? 50);
  const y = Number(layer.focus?.y ?? 50);
  return `object-position: ${x}% ${y}%`;
}

// Edge to edge and always cropped: filling the card is the point of it. The
// focus picks which part of the picture stays in view.
function fillLayerHtml(layer, url) {
  if (!url) return '<div class="card-fill card-fill-missing"></div>';
  return `<img class="card-fill" src="${url}" alt="" style="${focusStyle(layer)}" draggable="false">`;
}

/* Async because image blobs come out of IndexedDB. The caller awaits it
   before swapping the markup in, so a card never paints its text first and
   its picture a frame later.

   `resolveImage` is where an image id becomes a URL. The editor's own cards
   come out of IndexedDB; a shared screen passes its own resolver, since its
   pictures arrived over the connection and were never stored. */
export async function renderCard(card, target, { presenting = false, resolveImage = imageUrl } = {}) {
  const slots = groupLayers(card);
  const fill = fillImage(card);

  const urls = new Map();
  await Promise.all(
    slots
      .filter((s) => s.kind === "image")
      .flatMap((s) => s.layers)
      .concat(fill ? [fill] : [])
      .map(async (layer) => {
        urls.set(layer.id, await resolveImage(layer.imageId));
      })
  );

  const background = fill ? fillLayerHtml(fill, urls.get(fill.id)) : "";
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

  target.className = `card-canvas layout-${card.layout}${presenting ? " presenting" : ""}${fill ? " filled" : ""}`;
  target.innerHTML = background + (html || (fill ? "" : '<div class="card-empty">This card is empty</div>'));
}
