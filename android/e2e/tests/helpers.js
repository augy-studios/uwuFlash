import { expect } from "@playwright/test";

export const SHOTS = process.env.E2E_SHOTS || "test-results/shots";

/** The app, up and with its screen reader tree there to find things by. */
export async function openApp(page, query = "", { release = null } = {}) {
  // What the update check finds, as the real site isn't there to ask.
  await page.route("https://flash.uwuapps.org/api/app-release", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", headers: { "access-control-allow-origin": "*" }, body: JSON.stringify({ version: release }) }));
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    // Flutter's own complaints about drawing come through the console.
    if (m.type() === "error" && !/favicon|Failed to load resource/.test(m.text())) errors.push(m.text());
  });
  await page.goto(`/${query}`);
  await expect(page.getByRole("button", { name: "Present fullscreen" })).toBeVisible();
  page.flashErrors = errors;
  return errors;
}

export const button = (page, name, exact = true) => page.getByRole("button", { name, exact });

/** What the app asked of its Java side. */
export const calls = (page) => page.evaluate(() => Array.from(window.e2eCalls).map((c) => JSON.parse(c)));

export const lastCall = async (page, method) => {
  const all = (await calls(page)).filter((c) => c.method === method);
  return all[all.length - 1];
};

/** What the Java side would have said. */
export const emit = (page, plugin, event, data = {}) =>
  page.evaluate(([p, e, d]) => window.e2eEmit(p, e, JSON.stringify(d)), [plugin, event, data]);

/** What the app keeps, as the store has it. */
export const stored = (page, key) =>
  page.evaluate((k) => {
    const v = localStorage.getItem(`flutter.ls.${k}`);
    return v === null ? null : JSON.parse(v);
  }, key);

export const deck = async (page) => JSON.parse(await stored(page, "uwuflash.deck"));

/** Types into the layer's text box. */
export async function typeCard(page, text) {
  const box = page.getByRole("textbox").first();
  await box.click();
  // The browser's text box is made a moment after the tap.
  await page.waitForTimeout(250);
  await page.keyboard.press("Control+A");
  await page.keyboard.type(text);
  await page.waitForTimeout(600); // past the save's 400 ms
}

export async function shot(page, name) {
  await page.waitForTimeout(450);
  await page.screenshot({ path: `${SHOTS}/${name}.png` });
}

/** A small real PNG, in the given colour, for picking as a picture. */
export function png(r = 200, g = 60, b = 90, size = 8) {
  // Uncompressed DEFLATE blocks, CRCs by table: enough for a valid file with no dependencies.
  const table = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = table[(c ^ b) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const t = Buffer.from(type, "latin1");
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4);
    sum.writeUInt32BE(crc(Buffer.concat([t, data])));
    return Buffer.concat([len, t, data, sum]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(Math.round(size / 2), 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const height = Math.round(size / 2);
  const raw = Buffer.alloc(height * (1 + size * 3));
  for (let y = 0; y < height; y++) {
    const row = y * (1 + size * 3);
    raw[row] = 0;
    for (let x = 0; x < size; x++) {
      raw[row + 1 + x * 3] = r;
      raw[row + 2 + x * 3] = g;
      raw[row + 3 + x * 3] = b;
    }
  }
  const adler = (() => {
    let a = 1;
    let d = 0;
    for (const v of raw) {
      a = (a + v) % 65521;
      d = (d + a) % 65521;
    }
    return ((d << 16) | a) >>> 0;
  })();
  const blocks = [];
  for (let at = 0; at < raw.length; at += 65535) {
    const part = raw.subarray(at, at + 65535);
    const head = Buffer.alloc(5);
    head[0] = at + 65535 >= raw.length ? 1 : 0;
    head.writeUInt16LE(part.length, 1);
    head.writeUInt16LE(part.length ^ 0xffff, 3);
    blocks.push(head, part);
  }
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE(adler);
  const idat = Buffer.concat([Buffer.from([0x78, 0x01]), ...blocks, tail]);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}

/** Picks a picture through the app's file chooser. */
export async function pickPicture(page, trigger, name = "picture.png", body = png()) {
  const chooser = page.waitForEvent("filechooser");
  await trigger.click();
  await (await chooser).setFiles({ name, mimeType: name.endsWith(".txt") ? "text/plain" : "image/png", buffer: body });
}

/** Chromium's pixels as a colour at a point of the page, as #rrggbb. */
export async function pixel(page, x, y) {
  const shotBuf = await page.screenshot({ clip: { x, y, width: 1, height: 1 } });
  return page.evaluate(async (b64) => {
    const img = new Image();
    img.src = `data:image/png;base64,${b64}`;
    await img.decode();
    const c = document.createElement("canvas");
    c.width = c.height = 1;
    const g = c.getContext("2d");
    g.drawImage(img, 0, 0);
    const [r, gr, bl] = g.getImageData(0, 0, 1, 1).data;
    return `#${[r, gr, bl].map((n) => n.toString(16).padStart(2, "0")).join("")}`;
  }, shotBuf.toString("base64"));
}
