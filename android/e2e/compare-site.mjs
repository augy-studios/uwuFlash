// Draws one deck on the real website and in the app, side by side, for checking card layouts by eye:
//
//     node compare-site.mjs      with serve.mjs running; pictures land in test-results/compare/
import { chromium, devices } from "@playwright/test";
import { png } from "./tests/helpers.js";

const OUT = "test-results/compare";
const cards = [
  { name: "words-photo-center", layout: "image-center", text: "Kept from one", size: "l", fit: "contain" },
  { name: "small-photo-center", layout: "image-center", text: "Small words", size: "s", fit: "contain" },
  { name: "words-photo-cover", layout: "image-center", text: "Kept from one", size: "l", fit: "cover" },
  { name: "small-photo-cover", layout: "image-center", text: "Small words", size: "s", fit: "cover" },
  { name: "small-between", layout: "image-between", text: "Small words", size: "s", fit: "contain", second: "Below it" },
  { name: "left", layout: "image-left", text: "Side by side", size: "m", fit: "contain" },
  { name: "right-cover", layout: "image-right", text: "Side by side", size: "m", fit: "cover" },
  { name: "no-wrap", layout: "image-center", text: "A very long line of words", size: "m", wrap: false },
];

function deckOf(c) {
  const layers = [];
  layers.push({ id: "t1", type: "text", text: c.text, size: c.size, align: "center", hidden: false });
  if (c.fit) layers.push({ id: "i1", type: "image", imageId: "img-compare", fit: c.fit, fill: false, focus: { x: 50, y: 50 }, hidden: false });
  if (c.second) layers.push({ id: "t2", type: "text", text: c.second, size: c.size, align: "center", hidden: false });
  return { version: 1, cards: [{ id: "c1", layout: c.layout, layers, ticker: false, tickerSpeed: "normal", wrap: c.wrap !== false }] };
}

const picture = png(40, 160, 90, 320);
const browser = await chromium.launch();
const device = { ...devices["Pixel 7"], viewport: { width: 412, height: 915 } };

for (const c of cards) {
  // The website.
  let context = await browser.newContext(device);
  let page = await context.newPage();
  await page.route(/googletagmanager|googlesyndication/, (r) => r.abort());
  // Before the page's scripts each time: it saves its own deck as it goes.
  await page.addInitScript((deck) => localStorage.setItem("uwuflash.deck", JSON.stringify(deck)), deckOf(c));
  await page.goto("http://127.0.0.1:4174/");
  await page.evaluate(async ([bytes]) => {
    await new Promise((resolve, reject) => {
      const open = indexedDB.open("uwuflash-images", 1);
      open.onupgradeneeded = () => open.result.createObjectStore("images");
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const t = open.result.transaction("images", "readwrite");
        t.objectStore("images").put(new Blob([new Uint8Array(bytes)], { type: "image/png" }), "img-compare");
        t.oncomplete = () => { open.result.close(); resolve(); };
      };
    });
  }, [[...picture]]);
  await page.reload();
  await page.waitForTimeout(800);
  await page.locator(".card-frame").screenshot({ path: `${OUT}/${c.name}-site.png` });
  await context.close();

  // The app, in the same look, so only the layout differs.
  context = await browser.newContext(device);
  page = await context.newPage();
  await page.route("https://flash.uwuapps.org/api/app-release", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*" }, body: '{"version":null}' }));
  await page.goto("http://127.0.0.1:4173/");
  await page.evaluate(([deck, b64]) => {
    localStorage.setItem("flutter.ls.uwuflash.deck", JSON.stringify(JSON.stringify(deck)));
    localStorage.setItem("flutter.ls.app.look", JSON.stringify("usual"));
    localStorage.setItem("flutter.img.img-compare", JSON.stringify(b64));
  }, [deckOf(c), picture.toString("base64")]);
  await page.reload();
  await page.getByRole("button", { name: "Present fullscreen", exact: true }).waitFor();
  await page.waitForTimeout(900);
  const box = await page.getByLabel(/^Card preview/).boundingBox();
  await page.screenshot({ path: `${OUT}/${c.name}-app.png`, clip: box });
  await context.close();
  console.log(c.name);
}
await browser.close();
