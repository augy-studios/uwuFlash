import { test, expect } from "@playwright/test";
import { openApp, button, typeCard, shot, emit, lastCall, deck, pickPicture, png } from "./helpers.js";

async function twoCards(page) {
  await typeCard(page, "Card one");
  await button(page, "New card").click();
  await typeCard(page, "Card two");
  await button(page, "New card").click();
  await typeCard(page, "Card three");
  await button(page, /^Card 1:/, false).click();
}

test.describe("presenting", () => {
  test.use({ viewport: { width: 412, height: 915 } });

  test.beforeEach(async ({ page }) => {
    await openApp(page, "?wallpaper=1");
    await twoCards(page);
  });

  test.afterEach(async ({ page }) => {
    expect(page.flashErrors).toEqual([]);
  });

  test("the screen is held: on, bright, every bar hidden, and let go after", async ({ page }) => {
    await button(page, "Present fullscreen").click();
    await expect(page.getByText("1 / 3").first()).toBeAttached();
    await shot(page, "you-present");
    expect((await lastCall(page, "screen")).options).toEqual({ awake: true, bright: true, immersive: true });
    expect((await lastCall(page, "keys")).options).toEqual({ on: true });

    await button(page, "Stop presenting").click();
    await expect(button(page, "Present fullscreen")).toBeVisible();
    expect((await lastCall(page, "screen")).options).toEqual({ awake: false, bright: false, immersive: false });
    expect((await lastCall(page, "keys")).options).toEqual({ on: false });
  });

  test("the sides of the screen, a swipe and the keyboard change cards", async ({ page }) => {
    await button(page, "Present fullscreen").click();
    const view = page.viewportSize();
    await button(page, "Next card").click();
    await expect(page.getByText("2 / 3").first()).toBeAttached();
    await button(page, "Previous card").click();
    await expect(page.getByText("1 / 3").first()).toBeAttached();
    // Not past either end.
    await button(page, "Previous card").click();
    await expect(page.getByText("1 / 3").first()).toBeAttached();

    await page.mouse.move(view.width * 0.6, view.height / 2);
    await page.mouse.down();
    await page.mouse.move(view.width * 0.2, view.height / 2, { steps: 5 });
    await page.mouse.up();
    await expect(page.getByText("2 / 3").first()).toBeAttached();

    await page.keyboard.press("ArrowRight");
    await expect(page.getByText("3 / 3").first()).toBeAttached();
    await page.keyboard.press("PageUp");
    await expect(page.getByText("2 / 3").first()).toBeAttached();
    await page.keyboard.press("Escape");
    await expect(button(page, "Present fullscreen")).toBeVisible();
  });

  test("the volume keys: down next, up before, held for the ticker", async ({ page }) => {
    await button(page, "Present fullscreen").click();
    await emit(page, "Flash", "key", { key: "next" });
    await expect(page.getByText("2 / 3").first()).toBeAttached();
    await emit(page, "Flash", "key", { key: "previous" });
    await expect(page.getByText("1 / 3").first()).toBeAttached();
    await emit(page, "Flash", "key", { key: "hold" });
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].ticker).toBe(true);
    await shot(page, "you-present-ticker");
  });

  test("flick: off until switched on, remembered, and turns the cards", async ({ page }) => {
    await button(page, "Present fullscreen").click();
    const flick = page.getByRole("switch", { name: "Flick to change cards" });
    await expect(flick).not.toBeChecked();
    await flick.click();
    await expect(page.getByText("Flick your wrist right").first()).toBeAttached();
    expect((await lastCall(page, "flick")).options).toEqual({ on: true });
    await emit(page, "Flash", "flick", { direction: 1 });
    await expect(page.getByText("2 / 3").first()).toBeAttached();
    await emit(page, "Flash", "flick", { direction: -1 });
    await expect(page.getByText("1 / 3").first()).toBeAttached();
    await button(page, "Stop presenting").click();
    expect((await lastCall(page, "flick")).options).toEqual({ on: false });

    // Off the tooltip a mouse left behind; a phone has no such thing.
    await page.mouse.move(5, 500);
    await page.waitForTimeout(300);
    await button(page, "Present fullscreen").click();
    expect((await lastCall(page, "flick")).options).toEqual({ on: true });
    await flick.click();
    expect((await lastCall(page, "flick")).options).toEqual({ on: false });
  });

  test("the ticker button rolls the card's words, and isn't there without words", async ({ page }) => {
    await button(page, "Present fullscreen").click();
    const ticker = page.getByRole("switch", { name: "Ticker for this card" });
    await ticker.click();
    await expect(ticker).toBeChecked();
    await page.waitForTimeout(600);
    expect((await deck(page)).cards[0].ticker).toBe(true);
    const a = await page.screenshot();
    await page.waitForTimeout(400);
    const b = await page.screenshot();
    expect(a.equals(b)).toBe(false);
    await button(page, "Stop presenting").click();

    await button(page, "New card").click();
    await button(page, "Delete layer").first().click();
    await button(page, "Present fullscreen").click();
    await expect(ticker).toHaveCount(0);
    await shot(page, "you-present-empty");
  });

  test("a picture filling the screen, with words over it", async ({ page }) => {
    await pickPicture(page, button(page, "Add image"), "fill.png", png(30, 110, 220, 40));
    await button(page, "Fill the screen").click();
    await button(page, "Present fullscreen").click();
    await shot(page, "you-present-fill");
  });
});
