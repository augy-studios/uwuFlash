import { test, expect } from "@playwright/test";
import { openApp, button, stored, typeCard, shot, pixel } from "./helpers.js";

// A point on the card's preview that stays background whatever's typed: its top left corner, inside
// the rounded edge.
async function cardColour(page) {
  const box = await page.getByLabel(/^Card preview/).boundingBox();
  return pixel(page, Math.round(box.x + 24), Math.round(box.y + 24));
}

test.describe("the two looks", () => {
  test("Material You is the default, in the phone's colours", async ({ page }) => {
    const errors = await openApp(page, "?wallpaper=1");
    expect(await stored(page, "app.look")).toBeNull();
    await button(page, "Theme").click();
    await expect(page.getByRole("switch", { name: "Material You" })).toBeChecked();
    await expect(button(page, "Your phone's")).toBeVisible();
    await shot(page, "you-theme-sheet");
    await button(page, "Close").click();
    await page.waitForTimeout(400);
    // The fake wallpaper is purple, and the card takes it: blue over green, not the classic green.
    const c = await cardColour(page);
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
    expect(b).toBeGreaterThan(g);
    expect(r).toBeGreaterThan(g - 10);
    expect(c).not.toBe("#ccffcc");
    expect(errors).toEqual([]);
  });

  test("Settings switches it off for the usual UwU Apps theme, and back", async ({ page }) => {
    const errors = await openApp(page, "?wallpaper=1");
    await button(page, "Settings").click();
    await shot(page, "you-settings");
    const sw = page.getByRole("switch", { name: "Material You" });
    await expect(sw).toBeChecked();
    await sw.click();
    await expect(sw).not.toBeChecked();
    expect(await stored(page, "app.look")).toBe("usual");
    await shot(page, "uwu-settings");
    await button(page, "Close").click();
    await page.waitForTimeout(500);
    await typeCard(page, "Hello room");
    await shot(page, "uwu-editor");
    // The site's rule: in light mode the card is the chosen colour, classic to start with.
    expect(await cardColour(page)).toBe("#ccffcc");

    // Remembered.
    await page.reload();
    await expect(button(page, "Present fullscreen")).toBeVisible();
    await page.waitForTimeout(400);
    expect(await cardColour(page)).toBe("#ccffcc");

    await button(page, "Settings").click();
    await page.getByRole("switch", { name: "Material You" }).click();
    expect(await stored(page, "app.look")).toBeNull();
    expect(errors).toEqual([]);
  });

  test("the UwU Apps theme: brand colours and modes, as the site has them", async ({ page }) => {
    await openApp(page);
    await button(page, "Theme").click();
    await page.getByRole("switch", { name: "Material You" }).click();
    await expect(button(page, "Your phone's")).toHaveCount(0);
    for (const label of ["Classic", "Not green 1", "Not green 2", "Not green 3", "Not green 4", "Not green 5", "Really really light green"]) {
      await expect(button(page, label)).toBeVisible();
    }
    await button(page, "Not green 2").click();
    expect(await stored(page, "uwuflash.colorTheme")).toBe("not-green-2");
    await shot(page, "uwu-theme-sheet");
    await button(page, "Close").click();
    await page.waitForTimeout(500);
    expect(await cardColour(page)).toBe("#ccccff");

    // Dark: near black, with the words in the chosen colour.
    await button(page, "Theme").click();
    await button(page, "Dark").click();
    expect(await stored(page, "uwuflash.mode")).toBe("dark");
    await button(page, "Close").click();
    await page.waitForTimeout(500);
    expect(await cardColour(page)).toBe("#0c100e");
    await shot(page, "uwu-dark");

    await button(page, "Theme").click();
    await button(page, "Time-based").click();
    await expect(page.getByText(/Following the clock\. Currently (light|dark)\./).first()).toBeAttached();
    expect(await stored(page, "uwuflash.mode")).toBe("time");
    expect(page.flashErrors).toEqual([]);
  });

  test("Material You follows the phone's light or dark by default, and a brand colour can stand in", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await openApp(page, "?wallpaper=1");
    await page.waitForTimeout(400);
    await shot(page, "you-dark");
    const dark = await cardColour(page);
    expect(parseInt(dark.slice(1, 3), 16)).toBeLessThan(0x40);
    await page.emulateMedia({ colorScheme: "light" });
    await page.waitForTimeout(500);
    const light = await cardColour(page);
    expect(parseInt(light.slice(1, 3), 16)).toBeGreaterThan(0x80);

    await button(page, "Theme").click();
    await button(page, "Not green 1").click();
    expect(await stored(page, "app.youColours")).toBe("brand");
    await button(page, "Close").click();
    await page.waitForTimeout(500);
    const red = await cardColour(page);
    expect(parseInt(red.slice(1, 3), 16)).toBeGreaterThan(parseInt(red.slice(3, 5), 16));

    // Back to the phone's.
    await button(page, "Theme").click();
    await button(page, "Your phone's").click();
    expect(await stored(page, "app.youColours")).toBeNull();
    expect(page.flashErrors).toEqual([]);
  });
});
