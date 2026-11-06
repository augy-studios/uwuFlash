import { test, expect } from "@playwright/test";
import { openApp, button, deck, stored, typeCard, shot, pickPicture, emit, lastCall, png } from "./helpers.js";

test.describe("the editor", () => {
  test.beforeEach(async ({ page }) => {
    await openApp(page, "?wallpaper=1");
  });

  test.afterEach(async ({ page }) => {
    expect(page.flashErrors).toEqual([]);
  });

  test("first open: the brand line, one blank card, every panel", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "uwuFlash" })).toBeVisible();
    for (const name of ["Where the image sits", "Ticker", "Layers", "Cards"]) {
      await expect(page.getByRole("heading", { name, exact: true })).toBeAttached();
    }
    await expect(page.getByText("1 of 1").first()).toBeAttached();
    await shot(page, "you-first-open");
  });

  test("words typed go on the card and are saved in the site's shape", async ({ page }) => {
    await typeCard(page, "Hello room");
    await expect(button(page, "Hello room")).toBeVisible();
    const saved = await deck(page);
    expect(saved.version).toBe(1);
    expect(saved.cards[0]).toMatchObject({ layout: "image-center", ticker: false, tickerSpeed: "normal", wrap: true });
    expect(saved.cards[0].layers[0]).toMatchObject({ type: "text", text: "Hello room", size: "l", align: "center", hidden: false });
    expect(saved.cards[0].layers[0].id).toMatch(/^[a-z0-9]+-[a-z0-9]+$/);
    await page.reload();
    await expect(button(page, "Hello room")).toBeVisible();
  });

  test("size and alignment", async ({ page }) => {
    await typeCard(page, "Big");
    await button(page, "Huge").click();
    await button(page, "Right").click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].layers[0]).toMatchObject({ size: "xl", align: "right" });
    await shot(page, "you-huge-right");
  });

  test("layers: add, select, reorder, hide, delete", async ({ page }) => {
    await typeCard(page, "First");
    await button(page, "Add text").click();
    await typeCard(page, "Second");
    await expect(button(page, "First")).toBeVisible();
    await expect(button(page, "Second")).toBeVisible();
    let layers = (await deck(page)).cards[0].layers;
    expect(layers.map((l) => l.text)).toEqual(["First", "Second"]);

    // The top row, the last in the list, has nowhere further forward to go.
    await expect(button(page, "Bring forward").first()).toBeDisabled();
    await button(page, "Send backward").first().click();
    await page.waitForTimeout(600);
    layers = (await deck(page)).cards[0].layers;
    expect(layers.map((l) => l.text)).toEqual(["Second", "First"]);

    await button(page, "Hide layer").first().click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].layers.filter((l) => l.hidden)).toHaveLength(1);
    await expect(button(page, /^Show layer/, false)).toBeVisible();

    await button(page, "Delete layer").first().click();
    await button(page, "Delete layer").first().click();
    await expect(page.getByText("No layers yet. Add text or an image.").first()).toBeAttached();
    await expect(page.getByText("Select a layer to edit it.").first()).toBeAttached();
    await shot(page, "you-no-layers");
  });

  test("speaking adds a line and keeps what was typed", async ({ page }) => {
    await typeCard(page, "Typed");
    await button(page, "Speak").click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].layers[0].text).toBe("Typed\nSpoken words");
  });

  test("the card's ticker, its speed, and wrapping", async ({ page }) => {
    await typeCard(page, "Roll me");
    await page.getByRole("switch", { name: "Ticker off" }).click();
    await expect(page.getByRole("switch", { name: "Ticker on" })).toBeVisible();
    await button(page, "Fast").click();
    // A ticker never wraps, so the wrap switch goes with it on.
    await expect(page.getByRole("switch", { name: /Wrapping/ })).toHaveCount(0);
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0]).toMatchObject({ ticker: true, tickerSpeed: "fast" });
    await page.getByRole("switch", { name: "Ticker on" }).click();
    await page.getByRole("switch", { name: "Wrapping on" }).click();
    await expect(page.getByRole("switch", { name: "Wrapping off" })).toBeVisible();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0]).toMatchObject({ ticker: false, wrap: false });
  });

  test("cards: new, duplicate, move, delete", async ({ page }) => {
    await typeCard(page, "One");
    await button(page, "New card").click();
    await expect(page.getByText("2 of 2").first()).toBeAttached();
    await typeCard(page, "Two");
    await button(page, "Duplicate").click();
    await expect(page.getByText("3 of 3").first()).toBeAttached();
    await page.waitForTimeout(600);
    let saved = await deck(page);
    expect(saved.cards.map((c) => c.layers[0].text)).toEqual(["One", "Two", "Two"]);
    expect(saved.cards[1].id).not.toBe(saved.cards[2].id);
    expect(saved.cards[1].layers[0].id).not.toBe(saved.cards[2].layers[0].id);

    // Editing the copy leaves the original.
    await typeCard(page, "Copy");
    saved = await deck(page);
    expect(saved.cards.map((c) => c.layers[0].text)).toEqual(["One", "Two", "Copy"]);

    await button(page, "Move card earlier").click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards.map((c) => c.layers[0].text)).toEqual(["One", "Copy", "Two"]);
    await expect(page.getByText("2 of 3").first()).toBeAttached();

    await button(page, /^Card 1:/, false).click();
    await expect(page.getByText("1 of 3").first()).toBeAttached();
    await button(page, "Delete").click();
    await page.waitForTimeout(100);
    expect((await deck(page)).cards.map((c) => c.layers[0].text)).toEqual(["Copy", "Two"]);

    await button(page, "Delete").click();
    await button(page, "Delete").click();
    // Never left with nothing in it.
    await expect(page.getByText("1 of 1").first()).toBeAttached();
  });

  test("pictures: add, refuse what isn't one, fit, fill the screen and move the crop", async ({ page }) => {
    await pickPicture(page, button(page, "Add image"), "notes.txt", Buffer.from("not a picture"));
    await expect(page.getByText("That file is not an image.").first()).toBeAttached();
    expect(await stored(page, "uwuflash.deck")).toBeNull();

    await pickPicture(page, button(page, "Add image"), "wide.png", png(220, 40, 90, 40));
    await expect(button(page, "Image", true)).toBeVisible();
    await page.waitForTimeout(100);
    let image = (await deck(page)).cards[0].layers[1];
    expect(image).toMatchObject({ type: "image", fit: "contain", fill: false, focus: { x: 50, y: 50 } });
    expect(image.imageId).toMatch(/^img-[a-z0-9-]+$/);
    await shot(page, "you-picture-contain");

    await button(page, "Fill the space").click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].layers[1].fit).toBe("cover");
    await shot(page, "you-picture-cover");

    await button(page, "Fill the screen").click();
    await page.waitForTimeout(600);
    image = (await deck(page)).cards[0].layers[1];
    expect(image.fill).toBe(true);
    await expect(page.getByText("Drag the picture in the preview").first()).toBeAttached();
    await shot(page, "you-picture-fill");

    // A 2:1 picture on a 16:10 card has room to crop across, none down.
    const box = await page.getByLabel("Card preview. Drag the picture").boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.waitForTimeout(150);
    await page.mouse.move(box.x + box.width / 2 + 40, box.y + box.height / 2 + 15, { steps: 6 });
    await page.mouse.up();
    await page.waitForTimeout(600);
    image = (await deck(page)).cards[0].layers[1];
    expect(image.focus.x).toBeLessThan(50);
    expect(image.focus.y).toBe(50);

    await button(page, "Re-centre").click();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].layers[1].focus).toEqual({ x: 50, y: 50 });

    // A second picture, and filling the card isn't on offer any more.
    await pickPicture(page, button(page, "Add image"), "two.png", png(30, 90, 200, 16));
    await page.waitForTimeout(100);
    await expect(button(page, "Fill the screen")).toHaveCount(0);

    // Deleted, its file goes too.
    const before = await page.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith("flutter.img.")).length);
    expect(before).toBe(2);
    await button(page, "Delete layer").first().click();
    await page.waitForTimeout(200);
    expect(await page.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith("flutter.img.")).length)).toBe(1);
  });

  test("every layout draws with words and a picture", async ({ page }) => {
    await typeCard(page, "Words here");
    await pickPicture(page, button(page, "Add image"), "pic.png", png(40, 160, 90, 40));
    for (const name of ["Image centre", "Image left of text", "Image right of text", "Image between text"]) {
      await button(page, name).click();
      await shot(page, `you-layout-${name.replaceAll(" ", "-").toLowerCase()}`);
    }
    for (const fit of ["Fill the space"]) {
      await button(page, fit).click();
      for (const name of ["Image centre", "Image left of text", "Image right of text"]) {
        await button(page, name).click();
        await shot(page, `you-bleed-${name.replaceAll(" ", "-").toLowerCase()}`);
      }
    }
  });
});

test.describe("the Edge Tray", () => {
  test("holds Share, Present, the app's own and the global actions, and tucks away", async ({ page }) => {
    const errors = await openApp(page, "?wallpaper=1");
    const names = ["Share screen", "Present fullscreen", "Notifications", "Check for updates", "Settings", "Theme"];
    for (const name of names) await expect(button(page, name)).toBeVisible();

    const y = await Promise.all(names.map(async (n) => (await button(page, n).boundingBox()).y));
    expect(y).toEqual([...y].sort((a, b) => a - b));

    const before = await button(page, "Hide menu").boundingBox();
    await button(page, "Hide menu").click();
    await expect(button(page, "Show menu")).toBeVisible();
    await page.waitForTimeout(450);
    await shot(page, "you-tray-collapsed");
    expect(await stored(page, "uwuflash.trayOpen")).toBe("0");
    // Off screen, and out of reach.
    for (const name of names) await expect(button(page, name)).toHaveCount(0);
    const tab = await button(page, "Show menu").boundingBox();
    const viewport = page.viewportSize();
    expect(Math.round(tab.x + tab.width)).toBe(viewport.width);
    expect(tab.x).toBeGreaterThan(before.x);

    // Remembered.
    await page.reload();
    await expect(button(page, "Show menu")).toBeVisible();
    await button(page, "Show menu").click();
    await expect(button(page, "Theme")).toBeVisible();
    await page.waitForTimeout(450);
    expect(await stored(page, "uwuflash.trayOpen")).toBe("1");
    expect(errors).toEqual([]);
  });

  test("Check for updates opens the update window", async ({ page }) => {
    await openApp(page);
    await button(page, "Check for updates").click();
    expect((await lastCall(page, "update")).options).toMatchObject({ check: true });
  });
});

test.describe("what else the app was opened with or told", () => {
  test("the update bar offers a newer version, and Not now puts it away", async ({ page }) => {
    await openApp(page, "", { release: "1.10.0" });
    await expect(page.getByText("Version 1.10.0 of the uwuFlash app is out.").first()).toBeAttached();
    await shot(page, "you-update-bar");
    await button(page, "Update").click();
    expect((await lastCall(page, "update")).options).toMatchObject({ check: false, version: "1.10.0" });
    await button(page, "Not now").click();
    await expect(button(page, "Update")).toHaveCount(0);
  });

  test("no bar when this is the newest", async ({ page }) => {
    await openApp(page, "", { release: "1.1.0" });
    await page.waitForTimeout(800);
    await expect(button(page, "Update")).toHaveCount(0);
  });

  test("a scanned share code joins, and anything else does nothing", async ({ page }) => {
    await openApp(page);
    await emit(page, "Flash", "open", { url: "https://flash.uwuapps.org/?join=notacode!!" });
    await page.waitForTimeout(300);
    await expect(button(page, "Stop showing shared cards")).toHaveCount(0);
    await emit(page, "Flash", "open", { url: "https://flash.uwuapps.org/?join=BCD234" });
    await expect(button(page, "Stop showing shared cards")).toBeVisible();
    await expect(page.getByText("Joining BCD 234...").first()).toBeAttached();
    expect(await stored(page, "uwuflash.shareRole")).toBe("guest");
    await button(page, "Stop showing shared cards").click();
    await expect(button(page, "Present fullscreen")).toBeVisible();
    expect(await stored(page, "uwuflash.shareRole")).toBeNull();
  });

  test("notifications: two switches, each a topic", async ({ page }) => {
    await openApp(page);
    await button(page, "Notifications").click();
    const releases = page.getByRole("switch", { name: "New versions of the app" });
    await expect(releases).not.toBeChecked();
    await releases.click();
    await expect(releases).toBeChecked();
    expect((await lastCall(page, "setTopic")).options).toEqual({ topic: "releases", on: true });
    await shot(page, "you-notifications");
    await page.getByRole("switch", { name: "News from uwuFlash" }).click();
    expect((await lastCall(page, "setTopic")).options).toEqual({ topic: "news", on: true });
  });
});
