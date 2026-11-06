// Sharing for real, over the real PeerJS broker and WebRTC between browser contexts: the Flutter app
// with the actual website (main-site/, on port 4174), both ways round, and with itself.
import { test, expect, devices } from "@playwright/test";
import { openApp, button, typeCard, shot, stored, deck, pickPicture, png, SHOTS } from "./helpers.js";

const SITE = "http://127.0.0.1:4174";

// The website, without its analytics and ads, which have nothing to do with sharing.
async function openSite(context, query = "") {
  const page = await context.newPage();
  await page.route(/googletagmanager|googlesyndication/, (r) => r.abort());
  await page.goto(`${SITE}/${query}`);
  await page.waitForFunction(() => document.getElementById("presentBtn"));
  return page;
}

// Another copy of the app, on a phone of its own: its own storage, as a page in the same context
// would share the first one's.
async function secondPhone(browser) {
  const context = await browser.newContext({ ...devices["Pixel 7"], viewport: { width: 412, height: 2000 }, baseURL: "http://127.0.0.1:4173" });
  const page = await context.newPage();
  await openApp(page);
  return page;
}

async function startHostingApp(page, mode) {
  await button(page, /Share screen/, false).click();
  if (mode) await button(page, mode).click();
  await button(page, "Start sharing").click();
  await expect(page.getByText(/Waiting for/).first()).toBeAttached({ timeout: 25_000 });
  const code = await stored(page, "uwuflash.hostCode");
  expect(code).toMatch(/^[BCDFGHJKLMNPQRSTVWXYZ2-9]{6}$/);
  return code;
}

async function closeSheet(page) {
  await button(page, "Close").click();
  await page.waitForTimeout(350);
}

async function joinFromApp(page, code) {
  await button(page, /Share screen/, false).click();
  await page.getByRole("textbox", { name: "Code" }).click();
  // The browser's text box is made a moment after the tap.
  await page.waitForTimeout(250);
  await page.keyboard.type(code);
  await button(page, "Join").click();
}

test.describe("sharing with the website", () => {
  test.setTimeout(150_000);

  test("Mirror: the app shows a card on the site's screen, ticker and all", async ({ context, page }) => {
    await openApp(page, "?wallpaper=1");
    await typeCard(page, "From the app");
    const code = await startHostingApp(page);
    await shot(page, "you-share-sheet");

    const site = await openSite(context, `?join=${code}`);
    await expect(site.locator("#viewerTitle")).toHaveText("Ready", { timeout: 40_000 });
    await expect(page.getByText(/Connected\. The other screen shows your cards/).first()).toBeAttached();
    await expect(page.getByText("Other screen, connected").first()).toBeAttached();

    await closeSheet(page);
    await button(page, /Sharing screen/, false).isVisible();
    await button(page, "Present fullscreen").click();
    await expect(site.locator("#viewerCanvas")).toContainText("From the app");
    await site.screenshot({ path: `${SHOTS}/site-guest-mirror.png` });

    // A step, and a ticker, reach it too.
    await page.getByRole("switch", { name: "Ticker for this card" }).click();
    await expect(site.locator("#viewerCanvas .ticker")).toBeVisible();
    await page.getByRole("switch", { name: "Ticker for this card" }).click();

    await button(page, "Stop presenting").click();
    await expect(site.locator("#viewer")).not.toHaveClass(/showing/);
    expect(page.flashErrors).toEqual([]);
    await site.close();
  });

  test("a picture reaches the site's screen, in chunks", async ({ context, page }) => {
    await openApp(page);
    await typeCard(page, "With a photo");
    await pickPicture(page, button(page, "Add image"), "large.png", png(20, 180, 120, 600));
    const code = await startHostingApp(page);
    const site = await openSite(context, `?join=${code}`);
    await expect(site.locator("#viewerTitle")).toHaveText("Ready", { timeout: 40_000 });
    await closeSheet(page);
    await button(page, "Present fullscreen").click();
    await expect(site.locator("#viewerCanvas img.card-image")).toBeVisible();
    const ok = await site.locator("#viewerCanvas img.card-image").evaluate(async (img) => {
      await img.decode();
      return img.naturalWidth;
    });
    expect(ok).toBeGreaterThan(100);
    await site.screenshot({ path: `${SHOTS}/site-guest-picture.png` });
    expect(page.flashErrors).toEqual([]);
    await site.close();
  });

  test("the app is the other screen for the site", async ({ context, page }) => {
    const site = await openSite(context);
    await site.locator(".card-frame").waitFor();
    await site.locator("#layerText").fill("From the website");
    await site.locator("#shareBtn").click();
    await site.locator("#shareStart").click();
    await expect(site.locator("#shareStatus")).toContainText("Waiting", { timeout: 30_000 });
    const code = (await site.locator("#shareCode").textContent()).replace(/\s/g, "");

    await openApp(page, "?wallpaper=1");
    await joinFromApp(page, code);
    await expect(page.getByText(/^Ready$/).first()).toBeAttached({ timeout: 40_000 });
    await shot(page, "you-guest-ready");
    await expect(site.locator("#shareStatus")).toContainText("Connected");

    await site.locator('[data-close-modal="shareModal"]').click();
    await site.locator("#presentBtn").click();
    await expect(page.getByText("From the website").first()).toBeAttached();
    await shot(page, "you-guest-card");

    // The site stops, and the app says so rather than trying to come back.
    await site.keyboard.press("Escape");
    await site.locator("#shareBtn").click();
    await site.locator("#shareStop").click();
    await expect(page.getByText("Sharing ended").first()).toBeAttached();
    await button(page, "Back to my cards").click();
    await expect(button(page, "Present fullscreen")).toBeVisible();
    expect(page.flashErrors).toEqual([]);
    await site.close();
  });

  test("Send cards: the site gets the app's deck, pictures and hidden layers", async ({ context, page }) => {
    await openApp(page);
    await typeCard(page, "Sent card");
    await button(page, "Add text").click();
    await typeCard(page, "Hidden words");
    await button(page, "Hide layer").first().click();
    await pickPicture(page, button(page, "Add image"), "sent.png", png(200, 30, 200, 200));
    const code = await startHostingApp(page, "Send cards");

    const site = await openSite(context, `?join=${code}`);
    await expect(site.locator("#viewerTitle")).toHaveText("Copy cards", { timeout: 40_000 });
    await expect(site.locator("#viewerAdd")).toBeEnabled({ timeout: 20_000 });
    await site.locator("#viewerAdd").click();
    await expect(page.getByText("The other device copied your cards.").first()).toBeAttached();

    const copied = await site.evaluate(() => JSON.parse(localStorage.getItem("uwuflash.deck")));
    expect(copied.cards[0].layers.map((l) => l.type)).toEqual(["text", "text", "image"]);
    expect(copied.cards[0].layers[1]).toMatchObject({ text: "Hidden words", hidden: true });
    expect(page.flashErrors).toEqual([]);
    await site.close();
  });

  test("Send cards: the app takes the site's deck, Replace needing a second tap", async ({ context, page }) => {
    const site = await openSite(context);
    await site.locator("#layerText").fill("Site deck card");
    await site.locator("#imageInput").setInputFiles({ name: "s.png", mimeType: "image/png", buffer: png(10, 200, 200, 60) });
    await site.locator('.layer-row button[data-select]').first().waitFor();
    await site.waitForTimeout(600);
    await site.locator("#shareBtn").click();
    await site.locator('[data-share-mode="send"]').click();
    await site.locator("#shareStart").click();
    await expect(site.locator("#shareStatus")).toContainText("Waiting", { timeout: 30_000 });
    const code = (await site.locator("#shareCode").textContent()).replace(/\s/g, "");

    await openApp(page);
    await typeCard(page, "Mine already");
    await joinFromApp(page, code);
    await expect(button(page, "Replace my cards")).toBeEnabled({ timeout: 40_000 });
    await expect(page.getByText(/1 card from the other device/).first()).toBeAttached();
    await shot(page, "you-guest-offer");
    await button(page, "Replace my cards").click();
    await expect(button(page, "Tap again to replace")).toBeVisible();
    await button(page, "Tap again to replace").click();
    await expect(button(page, "Present fullscreen")).toBeVisible();
    await page.waitForTimeout(500);

    const mine = await deck(page);
    expect(mine.cards).toHaveLength(1);
    expect(mine.cards[0].layers.map((l) => l.type)).toEqual(["text", "image"]);
    expect(mine.cards[0].layers[0].text).toBe("Site deck card");
    // Stored here, under an id of this device's making.
    const image = mine.cards[0].layers[1].imageId;
    expect(await page.evaluate((id) => localStorage.getItem(`flutter.img.${id}`) !== null, image)).toBe(true);
    await shot(page, "you-after-import");
    expect(page.flashErrors).toEqual([]);
    await site.close();
  });
});

test.describe("sharing between two apps, and a Big Screen", () => {
  test.setTimeout(120_000);

  test("Extend: the presenter view here, the card there, in this phone's colours", async ({ browser, page }) => {
    await openApp(page, "?wallpaper=1");
    await typeCard(page, "Now card");
    await button(page, "New card").click();
    await typeCard(page, "Next card");
    await button(page, /^Card 1:/, false).click();
    const code = await startHostingApp(page, "Extend");

    const other = await secondPhone(browser);
    await joinFromApp(other, code);
    await expect(other.getByText(/^Ready$/).first()).toBeAttached({ timeout: 40_000 });

    await closeSheet(page);
    await button(page, "Present fullscreen").click();
    await expect(page.getByText("On the other screen").first()).toBeAttached();
    await shot(page, "you-presenter-view");
    await expect(other.getByText("Now card").first()).toBeAttached();
    await other.waitForTimeout(400);
    await other.screenshot({ path: `${SHOTS}/you-other-app-card.png` });
    await button(page, "Next card").click();
    await expect(other.getByText("Next card").first()).toBeAttached();

    await button(page, "Stop presenting").click();
    await expect(other.getByText(/^Ready$/).first()).toBeAttached();
    expect(page.flashErrors).toEqual([]);
    expect(other.flashErrors).toEqual([]);
    await other.context().close();
  });

  test("Big Screen: an app and the site take a piece each, numbered, and can be removed", async ({ browser, context, page }) => {
    await openApp(page, "?wallpaper=1");
    await typeCard(page, "Across every screen");
    const code = await startHostingApp(page, "Big Screen");
    await expect(page.getByText("No screens yet.").first()).toBeAttached();

    const site = await openSite(context, `?join=${code}`);
    await expect(site.locator("#viewerTitle")).toHaveText("Screen 1 of 1", { timeout: 40_000 });

    const other = await secondPhone(browser);
    await joinFromApp(other, code);
    await expect(other.getByText("Screen 2 of 2").first()).toBeAttached({ timeout: 40_000 });
    await expect(page.getByText("2 screens joined.").first()).toBeAttached();
    await expect(page.getByText("2 across").first()).toBeAttached();
    await page.waitForTimeout(500);
    await shot(page, "you-wall-sheet");

    // Numbers on every screen at once.
    await page.getByRole("switch", { name: "Show numbers" }).click();
    await expect(site.locator("#viewerNumber")).toBeVisible();
    await expect(site.locator("#viewerNumberValue")).toHaveText("1");
    await expect(other.getByText("of 2").first()).toBeAttached();
    await other.screenshot({ path: `${SHOTS}/you-wall-number.png` });
    await page.getByRole("switch", { name: "Hide numbers" }).click();
    await expect(site.locator("#viewerNumber")).toBeHidden();

    // Swapping places trades the pieces.
    await button(page, "Screen 1").click();
    await button(page, "Screen 2").click();
    // The first: while it slides, the site keeps a copy of what's leaving.
    await expect(site.locator("#viewerTitle").first()).toHaveText("Screen 2 of 2");
    await expect(other.getByText("Screen 1 of 2").first()).toBeAttached();

    // Fewer across, and thicker bezels, reach the screens.
    await button(page, "Thicker bezels").click();
    await expect(page.getByText("Bezels 9 mm").first()).toBeAttached();
    // Off the tooltip a mouse leaves behind; a phone has no such thing.
    await page.mouse.move(5, 5);
    await page.waitForTimeout(300);
    await page.getByRole("switch", { name: "Show lines" }).click();
    await other.waitForTimeout(500);
    await other.screenshot({ path: `${SHOTS}/you-wall-lines.png` });
    await page.getByRole("switch", { name: "Hide lines" }).click();

    await closeSheet(page);
    await button(page, "Present fullscreen").click();
    await expect(page.getByText("On 2 screens").first()).toBeAttached();
    await shot(page, "you-wall-presenter");
    await expect(other.getByText("Across every screen").first()).toBeAttached();
    await other.waitForTimeout(400);
    await other.screenshot({ path: `${SHOTS}/you-wall-piece.png` });
    await site.screenshot({ path: `${SHOTS}/site-wall-piece.png` });
    await button(page, "Stop presenting").click();

    // Let one go: it's told, and doesn't try to come back.
    await button(page, /Sharing screen/, false).click();
    await button(page, "Remove screen 1").click();
    await expect(other.getByText("Removed").first()).toBeAttached();
    await expect(page.getByText("1 screen joined.").first()).toBeAttached();
    expect(page.flashErrors).toEqual([]);
    expect(other.flashErrors).toEqual([]);
    await other.context().close();
    await site.close();
  });

  test("a code nobody's sharing says so", async ({ page }) => {
    await openApp(page);
    await joinFromApp(page, "ZZZ999");
    await expect(page.getByText("Could not connect").first()).toBeAttached({ timeout: 30_000 });
    await expect(page.getByText(/Nobody is sharing with that code/).first()).toBeAttached();
    await button(page, "Leave").click();
    await expect(button(page, "Present fullscreen")).toBeVisible();
  });

  test("a mistyped code is caught before trying", async ({ page }) => {
    await openApp(page);
    await joinFromApp(page, "ABC");
    await expect(page.getByText(/A code is 6 characters/).first()).toBeAttached();
  });
});
