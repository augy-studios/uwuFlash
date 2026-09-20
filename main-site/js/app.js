import {
  COLOR_THEMES,
  applyColorTheme,
  applyMode,
  getStoredColorTheme,
  getStoredMode,
  getModePreference,
  initTheme,
} from "./theme.js";
import { hydrateIcons, openModal, closeModal, escapeHtml, toast } from "./ui.js";
import { initUpdateBar } from "./update.js";
import { loadDeck, saveDeck, putImage, forgetImageUrl, pruneImages } from "./store.js";
import {
  LAYOUTS,
  TEXT_SIZES,
  makeCard,
  makeDeck,
  makeTextLayer,
  makeImageLayer,
  normaliseDeck,
  referencedImageIds,
  move,
  cardSummary,
} from "./deck.js";
import { renderCard } from "./render.js";

/* ---- state ---- */

let deck = makeDeck();
let cardIndex = 0;
let selectedLayerId = null;
let presenting = false;

const el = {};

function currentCard() {
  return deck.cards[cardIndex];
}

function selectedLayer() {
  return currentCard().layers.find((l) => l.id === selectedLayerId) || null;
}

/* ---- persistence ---- */

let saveTimer = null;

// Typing into a card should not write to localStorage on every keystroke,
// but a deck must never be left unsaved either. Coalesce to the next idle
// moment, and flush on anything that could end the page.
function persist() {
  if (saveTimer !== null) clearTimeout(saveTimer);
  saveTimer = setTimeout(flush, 400);
}

function flush() {
  if (saveTimer !== null) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  if (!saveDeck(deck)) {
    toast("Could not save. Storage may be full.");
  }
}

/* ---- rendering ---- */

async function renderPreview() {
  await renderCard(currentCard(), el.preview, { presenting });
}

function renderLayerList() {
  const layers = currentCard().layers;

  if (layers.length === 0) {
    el.layerList.innerHTML = '<p class="empty-note">No layers yet. Add text or an image.</p>';
    return;
  }

  // Back to front in the array, top down in the list, the way a layers
  // panel reads.
  el.layerList.innerHTML = layers
    .map((layer, i) => {
      const label =
        layer.type === "image"
          ? "Image"
          : layer.text.trim()
            ? escapeHtml(layer.text.trim().slice(0, 28))
            : "Empty text";
      const selected = layer.id === selectedLayerId;

      return `
        <li class="layer-row${selected ? " selected" : ""}${layer.hidden ? " layer-hidden" : ""}">
          <button class="layer-main" type="button" data-select="${layer.id}">
            <span class="layer-icon" data-icon="${layer.type === "image" ? "image" : "text"}"></span>
            <span class="layer-label">${label}</span>
          </button>
          <span class="layer-actions">
            <button class="icon-btn small" type="button" data-toggle="${layer.id}"
              aria-label="${layer.hidden ? "Show layer" : "Hide layer"}">
              <span data-icon="${layer.hidden ? "eyeOff" : "eye"}"></span>
            </button>
            <button class="icon-btn small" type="button" data-raise="${layer.id}"
              aria-label="Bring forward"${i === layers.length - 1 ? " disabled" : ""}>
              <span data-icon="up"></span>
            </button>
            <button class="icon-btn small" type="button" data-lower="${layer.id}"
              aria-label="Send backward"${i === 0 ? " disabled" : ""}>
              <span data-icon="down"></span>
            </button>
            <button class="icon-btn small" type="button" data-remove="${layer.id}" aria-label="Delete layer">
              <span data-icon="trash"></span>
            </button>
          </span>
        </li>`;
    })
    .reverse()
    .join("");

  hydrateIcons(el.layerList);
}

function renderInspector() {
  const layer = selectedLayer();

  if (!layer) {
    el.inspector.innerHTML = '<p class="empty-note">Select a layer to edit it.</p>';
    return;
  }

  if (layer.type === "text") {
    el.inspector.innerHTML = `
      <label class="field">
        <span class="field-label">Text</span>
        <textarea id="layerText" rows="3" placeholder="Type what the room should read">${escapeHtml(layer.text)}</textarea>
      </label>
      <div class="field">
        <span class="field-label">Size</span>
        <div class="seg" id="layerSize">
          ${TEXT_SIZES.map(
            (s) =>
              `<button class="seg-btn${layer.size === s.id ? " active" : ""}" type="button"
                data-size="${s.id}" aria-pressed="${layer.size === s.id}">${s.label}</button>`
          ).join("")}
        </div>
      </div>
      <div class="field">
        <span class="field-label">Alignment</span>
        <div class="seg" id="layerAlign">
          ${["left", "center", "right"]
            .map(
              (a) =>
                `<button class="seg-btn${layer.align === a ? " active" : ""}" type="button"
                  data-align="${a}" aria-pressed="${layer.align === a}">${a[0].toUpperCase() + a.slice(1)}</button>`
            )
            .join("")}
        </div>
      </div>`;

    const textarea = el.inspector.querySelector("#layerText");
    textarea.addEventListener("input", () => {
      layer.text = textarea.value;
      renderPreview();
      renderLayerList();
      renderCardStrip();
      persist();
    });

    el.inspector.querySelector("#layerSize").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-size]");
      if (!btn) return;
      layer.size = btn.dataset.size;
      renderInspector();
      renderPreview();
      persist();
    });

    el.inspector.querySelector("#layerAlign").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-align]");
      if (!btn) return;
      layer.align = btn.dataset.align;
      renderInspector();
      renderPreview();
      persist();
    });

    return;
  }

  el.inspector.innerHTML = `
    <div class="field">
      <span class="field-label">Image fit</span>
      <div class="seg" id="layerFit">
        <button class="seg-btn${layer.fit === "contain" ? " active" : ""}" type="button"
          data-fit="contain" aria-pressed="${layer.fit === "contain"}">Fit whole image</button>
        <button class="seg-btn${layer.fit === "cover" ? " active" : ""}" type="button"
          data-fit="cover" aria-pressed="${layer.fit === "cover"}">Fill the space</button>
      </div>
    </div>
    <button class="btn btn-quiet" type="button" id="replaceImage">Replace image</button>`;

  el.inspector.querySelector("#layerFit").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-fit]");
    if (!btn) return;
    layer.fit = btn.dataset.fit;
    renderInspector();
    renderPreview();
    persist();
  });

  el.inspector.querySelector("#replaceImage").addEventListener("click", () => {
    el.imageInput.dataset.replaceLayer = layer.id;
    el.imageInput.click();
  });
}

function renderLayoutPicker() {
  const active = currentCard().layout;
  el.layoutPicker.querySelectorAll("[data-layout]").forEach((btn) => {
    const isActive = btn.dataset.layout === active;
    btn.classList.toggle("active", isActive);
    btn.setAttribute("aria-pressed", String(isActive));
  });
}

function renderCardStrip() {
  el.cardStrip.innerHTML = deck.cards
    .map(
      (card, i) => `
        <li>
          <button class="card-chip${i === cardIndex ? " active" : ""}" type="button" data-card="${i}">
            <span class="card-chip-num">${i + 1}</span>
            <span class="card-chip-text">${escapeHtml(cardSummary(card))}</span>
          </button>
        </li>`
    )
    .join("");

  el.cardCount.textContent = `${cardIndex + 1} of ${deck.cards.length}`;
}

function renderAll() {
  renderCardStrip();
  renderLayoutPicker();
  renderLayerList();
  renderInspector();
  renderPreview();
}

/* ---- card and layer actions ---- */

function selectCard(index) {
  if (index < 0 || index >= deck.cards.length) return;
  cardIndex = index;
  const layers = currentCard().layers;
  selectedLayerId = layers.length ? layers[layers.length - 1].id : null;
  renderAll();
}

function addCard() {
  deck.cards.splice(cardIndex + 1, 0, makeCard(""));
  selectCard(cardIndex + 1);
  persist();
}

function duplicateCard() {
  // Structured clone with fresh ids, so editing the copy does not edit the
  // original. The image blob is shared: two cards pointing at one blob is
  // exactly what a duplicate should be, and pruneImages only drops a blob
  // once no card at all refers to it.
  const source = currentCard();
  const copy = {
    ...structuredClone(source),
    id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
  };
  copy.layers = copy.layers.map((layer, i) => ({
    ...layer,
    id: `${Date.now().toString(36)}-${i}-${Math.random().toString(36).slice(2, 6)}`,
  }));

  deck.cards.splice(cardIndex + 1, 0, copy);
  selectCard(cardIndex + 1);
  persist();
}

async function deleteCard() {
  if (deck.cards.length === 1) {
    // Never leave the deck with nothing in it: an empty deck has no screen
    // to show and no obvious way back to one.
    deck.cards = [makeCard("")];
    cardIndex = 0;
  } else {
    deck.cards.splice(cardIndex, 1);
    cardIndex = Math.min(cardIndex, deck.cards.length - 1);
  }

  selectCard(cardIndex);
  flush();
  await pruneImages(referencedImageIds(deck));
}

function moveCard(delta) {
  const to = cardIndex + delta;
  if (!move(deck.cards, cardIndex, to)) return;
  cardIndex = to;
  renderAll();
  persist();
}

function addTextLayer() {
  const layer = makeTextLayer("");
  currentCard().layers.push(layer);
  selectedLayerId = layer.id;
  renderAll();
  persist();
  el.inspector.querySelector("#layerText")?.focus();
}

async function addImageLayer(file, replaceLayerId = null) {
  if (!file) return;

  if (!file.type.startsWith("image/")) {
    toast("That file is not an image.");
    return;
  }

  const imageId = `img-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;

  try {
    await putImage(imageId, file);
  } catch {
    toast("Could not store that image.");
    return;
  }

  if (replaceLayerId) {
    const layer = currentCard().layers.find((l) => l.id === replaceLayerId);
    if (layer) {
      forgetImageUrl(layer.imageId);
      layer.imageId = imageId;
      selectedLayerId = layer.id;
    }
  } else {
    const layer = makeImageLayer(imageId);
    currentCard().layers.push(layer);
    selectedLayerId = layer.id;
  }

  renderAll();
  flush();
  await pruneImages(referencedImageIds(deck));
}

async function removeLayer(layerId) {
  const layers = currentCard().layers;
  const index = layers.findIndex((l) => l.id === layerId);
  if (index === -1) return;

  const [removed] = layers.splice(index, 1);
  if (removed.type === "image") forgetImageUrl(removed.imageId);
  if (selectedLayerId === layerId) {
    selectedLayerId = layers.length ? layers[layers.length - 1].id : null;
  }

  renderAll();
  flush();
  await pruneImages(referencedImageIds(deck));
}

function reorderLayer(layerId, delta) {
  const layers = currentCard().layers;
  const from = layers.findIndex((l) => l.id === layerId);
  if (!move(layers, from, from + delta)) return;
  selectedLayerId = layerId;
  renderLayerList();
  renderPreview();
  persist();
}

/* ---- presenting ---- */

async function showPresentCard() {
  await renderCard(currentCard(), el.presentCanvas, { presenting: true });
  el.presentCount.textContent = `${cardIndex + 1} / ${deck.cards.length}`;
}

function stepCard(delta) {
  const next = cardIndex + delta;
  if (next < 0 || next >= deck.cards.length) return;
  cardIndex = next;
  showPresentCard();
}

async function enterPresent() {
  presenting = true;
  el.present.classList.remove("hidden");
  document.body.classList.add("presenting");
  await showPresentCard();

  // Fullscreen is a request, not a guarantee: iOS Safari refuses it outside
  // an installed PWA. The presenter is styled to fill the viewport on its
  // own, so a refusal costs the status bar and nothing else.
  try {
    await document.documentElement.requestFullscreen?.();
  } catch {
    /* fullscreen refused, the fixed overlay still covers the page */
  }

  try {
    // Holding up a signboard means not touching the screen for a while.
    wakeLock = (await navigator.wakeLock?.request("screen")) ?? null;
  } catch {
    /* wake lock unsupported or refused; the screen may dim */
  }
}

async function exitPresent() {
  presenting = false;
  el.present.classList.add("hidden");
  document.body.classList.remove("presenting");

  try {
    await wakeLock?.release();
  } catch {
    /* already released */
  }
  wakeLock = null;

  if (document.fullscreenElement) {
    try {
      await document.exitFullscreen();
    } catch {
      /* already out */
    }
  }

  selectCard(cardIndex);
}

let wakeLock = null;

// A screen lock is dropped when the tab is hidden and is not restored on its
// own, so a presenter who takes a call comes back to a screen that dims.
document.addEventListener("visibilitychange", async () => {
  if (!presenting || document.visibilityState !== "visible" || wakeLock) return;
  try {
    wakeLock = (await navigator.wakeLock?.request("screen")) ?? null;
  } catch {
    /* nothing to do */
  }
});

/* ---- theme modal ---- */

function buildThemeModal() {
  const grid = document.getElementById("swatchGrid");
  grid.innerHTML = COLOR_THEMES.map(
    (t) => `
      <button class="swatch" data-theme-id="${t.id}" style="--swatch-color:${t.hex}" type="button" aria-label="${t.label}">
        <span class="swatch-dot"></span>
        <span class="swatch-label">${t.label}</span>
      </button>`
  ).join("");

  syncThemeModalState();

  grid.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-theme-id]");
    if (!btn) return;
    applyColorTheme(btn.dataset.themeId);
    syncThemeModalState();
  });

  document.getElementById("modeToggle").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-mode]");
    if (!btn) return;
    applyMode(btn.dataset.mode);
    syncThemeModalState();
  });

  // A tab left open across 09:00 or 18:00 re-resolves itself; redraw the
  // modal so the note and pressed state stay in step with the change.
  document.addEventListener("uwu:modechange", syncThemeModalState);
}

function syncThemeModalState() {
  const activeTheme = getStoredColorTheme();
  const activePreference = getModePreference();
  const resolvedMode = getStoredMode();

  document.querySelectorAll("#swatchGrid .swatch").forEach((item) => {
    item.classList.toggle("active", item.dataset.themeId === activeTheme);
  });
  document.querySelectorAll("#modeToggle .mode-btn").forEach((item) => {
    const isActive = item.dataset.mode === activePreference;
    item.classList.toggle("active", isActive);
    item.setAttribute("aria-pressed", String(isActive));
  });

  const note = document.getElementById("modeNote");
  if (note) {
    note.hidden = activePreference !== "time";
    if (activePreference === "time") {
      note.textContent = `Following the clock. Currently ${resolvedMode}.`;
    }
  }

  updateThemeButtonIcon();
}

function updateThemeButtonIcon() {
  const span = document.querySelector("#themeBtn [data-icon]");
  if (!span) return;
  span.setAttribute("data-icon", getStoredMode() === "dark" ? "moon" : "sun");
  hydrateIcons(document.getElementById("themeBtn"));
}

function wireModals() {
  document.querySelectorAll("[data-close-modal]").forEach((btn) => {
    btn.addEventListener("click", () => closeModal(btn.dataset.closeModal));
  });
  document.querySelectorAll(".modal-backdrop").forEach((backdrop) => {
    backdrop.addEventListener("click", (e) => {
      if (e.target === backdrop) closeModal(backdrop.id);
    });
  });
  document.getElementById("themeBtn").addEventListener("click", () => openModal("themeModal"));
}

/* ---- wiring ---- */

function wireEditor() {
  el.layerList.addEventListener("click", (e) => {
    const select = e.target.closest("[data-select]");
    if (select) {
      selectedLayerId = select.dataset.select;
      renderLayerList();
      renderInspector();
      return;
    }

    const toggle = e.target.closest("[data-toggle]");
    if (toggle) {
      const layer = currentCard().layers.find((l) => l.id === toggle.dataset.toggle);
      if (layer) {
        layer.hidden = !layer.hidden;
        renderLayerList();
        renderPreview();
        persist();
      }
      return;
    }

    const raise = e.target.closest("[data-raise]");
    if (raise) return reorderLayer(raise.dataset.raise, 1);

    const lower = e.target.closest("[data-lower]");
    if (lower) return reorderLayer(lower.dataset.lower, -1);

    const remove = e.target.closest("[data-remove]");
    if (remove) return removeLayer(remove.dataset.remove);
  });

  el.layoutPicker.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-layout]");
    if (!btn) return;
    currentCard().layout = btn.dataset.layout;
    renderLayoutPicker();
    renderPreview();
    persist();
  });

  el.cardStrip.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-card]");
    if (!btn) return;
    selectCard(Number(btn.dataset.card));
  });

  document.getElementById("addTextBtn").addEventListener("click", addTextLayer);
  document.getElementById("addImageBtn").addEventListener("click", () => {
    delete el.imageInput.dataset.replaceLayer;
    el.imageInput.click();
  });

  el.imageInput.addEventListener("change", async () => {
    const file = el.imageInput.files?.[0];
    const replace = el.imageInput.dataset.replaceLayer || null;
    // Cleared before the await, so picking the same file twice in a row
    // still fires a change event the second time.
    el.imageInput.value = "";
    delete el.imageInput.dataset.replaceLayer;
    await addImageLayer(file, replace);
  });

  document.getElementById("addCardBtn").addEventListener("click", addCard);
  document.getElementById("duplicateCardBtn").addEventListener("click", duplicateCard);
  document.getElementById("deleteCardBtn").addEventListener("click", deleteCard);
  document.getElementById("cardBackBtn").addEventListener("click", () => moveCard(-1));
  document.getElementById("cardForwardBtn").addEventListener("click", () => moveCard(1));
  document.getElementById("presentBtn").addEventListener("click", enterPresent);
}

function wirePresenter() {
  // Tapping the sides switches cards, which is the whole gesture: somebody
  // holding a phone up switches with a thumb without looking at it.
  document.getElementById("presentPrev").addEventListener("click", () => stepCard(-1));
  document.getElementById("presentNext").addEventListener("click", () => stepCard(1));
  document.getElementById("presentExit").addEventListener("click", exitPresent);

  document.addEventListener("keydown", (e) => {
    if (!presenting) return;
    if (e.key === "ArrowRight" || e.key === "PageDown" || e.key === " ") {
      e.preventDefault();
      stepCard(1);
    } else if (e.key === "ArrowLeft" || e.key === "PageUp") {
      e.preventDefault();
      stepCard(-1);
    } else if (e.key === "Escape") {
      exitPresent();
    }
  });

  // Leaving fullscreen by the browser's own gesture, rather than the exit
  // button, has to close the presenter too or the page is left overlaid.
  document.addEventListener("fullscreenchange", () => {
    if (!document.fullscreenElement && presenting) exitPresent();
  });

  let touchX = null;
  el.present.addEventListener(
    "touchstart",
    (e) => {
      touchX = e.changedTouches[0].clientX;
    },
    { passive: true }
  );
  el.present.addEventListener(
    "touchend",
    (e) => {
      if (touchX === null) return;
      const dx = e.changedTouches[0].clientX - touchX;
      touchX = null;
      if (Math.abs(dx) > 60) stepCard(dx < 0 ? 1 : -1);
    },
    { passive: true }
  );
}

function boot() {
  initTheme();
  hydrateIcons();
  updateThemeButtonIcon();
  buildThemeModal();
  wireModals();

  el.preview = document.getElementById("preview");
  el.layerList = document.getElementById("layerList");
  el.inspector = document.getElementById("inspector");
  el.layoutPicker = document.getElementById("layoutPicker");
  el.cardStrip = document.getElementById("cardStrip");
  el.cardCount = document.getElementById("cardCount");
  el.imageInput = document.getElementById("imageInput");
  el.present = document.getElementById("present");
  el.presentCanvas = document.getElementById("presentCanvas");
  el.presentCount = document.getElementById("presentCount");

  el.layoutPicker.innerHTML = LAYOUTS.map(
    (l) =>
      `<button class="layout-btn" type="button" data-layout="${l.id}" aria-pressed="false">
        <span class="layout-thumb thumb-${l.id}" aria-hidden="true"></span>
        <span>${l.label}</span>
      </button>`
  ).join("");

  deck = normaliseDeck(loadDeck());
  cardIndex = 0;
  selectedLayerId = currentCard().layers[0]?.id ?? null;

  wireEditor();
  wirePresenter();
  renderAll();

  // A deck half written when the tab closes is worse than one written a
  // fraction early. pagehide fires where beforeunload does not, on iOS.
  window.addEventListener("pagehide", flush);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flush();
  });

  initUpdateBar();
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
