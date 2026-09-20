/* Persistence. Two stores, on purpose.

   Cards are small structured objects and live in localStorage, which is
   synchronous and so cannot leave a render half done.

   Images are blobs and live in IndexedDB. Putting them in localStorage would
   mean base64, which is a third larger again, against a quota of a few
   megabytes that the cards themselves also have to fit inside. A deck with
   four photographs in it would fill it.

   Everything here is local to the device. Nothing is uploaded, so the app
   works with no network at all, which is the point of a signboard you might
   be holding up in a car park. */

const APP_KEY = "uwuflash";
const DECK_KEY = `${APP_KEY}.deck`;

const DB_NAME = `${APP_KEY}-images`;
const DB_VERSION = 1;
const IMAGE_STORE = "images";

/* ---- cards ---- */

export function loadDeck() {
  try {
    const raw = localStorage.getItem(DECK_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed?.cards) ? parsed : null;
  } catch {
    // Corrupt storage is not worth crashing the app over. A fresh deck loses
    // less than a white screen does.
    return null;
  }
}

export function saveDeck(deck) {
  try {
    localStorage.setItem(DECK_KEY, JSON.stringify(deck));
    return true;
  } catch {
    return false;
  }
}

/* ---- images ---- */

let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) {
      reject(new Error("IndexedDB unavailable"));
      return;
    }

    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(IMAGE_STORE)) {
        db.createObjectStore(IMAGE_STORE);
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

  return dbPromise;
}

function tx(mode, run) {
  return openDb().then(
    (db) =>
      new Promise((resolve, reject) => {
        const transaction = db.transaction(IMAGE_STORE, mode);
        const store = transaction.objectStore(IMAGE_STORE);
        const request = run(store);
        transaction.onerror = () => reject(transaction.error);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      })
  );
}

export function putImage(id, blob) {
  return tx("readwrite", (store) => store.put(blob, id));
}

export function getImage(id) {
  return tx("readonly", (store) => store.get(id));
}

export function deleteImage(id) {
  return tx("readwrite", (store) => store.delete(id));
}

export function listImageIds() {
  return tx("readonly", (store) => store.getAllKeys());
}

/* Object URLs, cached by image id. A layer is redrawn on every edit, and
   minting a fresh URL each time leaks one per keystroke. */

const urlCache = new Map();

export async function imageUrl(id) {
  if (urlCache.has(id)) return urlCache.get(id);

  const blob = await getImage(id);
  if (!blob) return null;

  const url = URL.createObjectURL(blob);
  urlCache.set(id, url);
  return url;
}

export function forgetImageUrl(id) {
  const url = urlCache.get(id);
  if (!url) return;
  URL.revokeObjectURL(url);
  urlCache.delete(id);
}

/* Images outlive the layer that referenced it only until the next sweep.
   Called after a delete, so a deck that has had a lot of images swapped in
   and out does not keep every one of them forever. */
export async function pruneImages(keepIds) {
  try {
    const keep = new Set(keepIds);
    const all = await listImageIds();
    await Promise.all(
      all
        .filter((id) => !keep.has(id))
        .map((id) => {
          forgetImageUrl(id);
          return deleteImage(id);
        })
    );
  } catch {
    // Orphaned blobs cost space, not correctness. Not worth surfacing.
  }
}
