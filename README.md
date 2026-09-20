# uwuFlash

**flash.uwuapps.org**

Write something on the screen, make it big, and hold it up.

uwuFlash is a signboard you already have in your pocket. Type a line of text,
add a picture if it helps, and show it to somebody across a room, a car park,
an arrivals hall or a stage. Save as many screens as you like and flick
between them with a thumb, the way you would with a stack of cue cards.

Everything is kept on the device. There is no account, nothing is uploaded,
and the whole app works with no connection at all.

## What it does

**Write on the screen.** Type or paste text and it fills the card. Four sizes,
three alignments, as many lines as you want.

**Add a picture.** Attach an image and choose where it sits relative to the
words: centred, to the left of the text, to the right of it, or between two
blocks of text.

**Arrange the layers.** Text and images are layers, listed front to back like
PowerPoint or Photoshop. Reorder them, hide one without deleting it, or take
it off the card entirely.

**Show it full screen.** One button fills the screen with the card and gets
everything else out of the way. The screen is kept awake while you are
presenting, because a signboard that dims after thirty seconds is not one.

**Stack cards like flashcards.** Save as many screens as you need. While
presenting, tap the left or right third of the screen to move between them, or
swipe, or use the arrow keys. No menu to go back to.

**Pick a colour.** Seven colours, and a light and dark mode that can follow
the clock. The colour is the point rather than decoration: in light mode the
card is your colour with near black text, and in dark mode it is near black
with your colour as the text, which is what makes it readable across a room in
either.

## Using it

Open **flash.uwuapps.org**. Install it to the home screen if you want it to
open full screen like an app.

- Type in the text box to change the selected layer.
- **Add text** and **Add image** add layers to the current card.
- The four buttons under **Where the image sits** set the arrangement.
- **New card**, **Duplicate** and the arrows manage the stack.
- The play button at the top right starts presenting. Escape, the exit button,
  or leaving fullscreen stops it.

Your deck is saved as you work and is still there next time you open it.

## For developers

The app is in [`main-site/`](main-site/) and its own
[README](main-site/README.md) covers the file layout and how to run it. There
is no build step: static HTML, CSS and ES modules.

Three specifications at the root are the source of truth, and each is shared
across the uwuapps projects rather than written for this one:

| File | What it governs |
| --- | --- |
| `uwuapps-theme.md` | The theme system: seven brand colours, light and dark, and the time based mode. |
| `uwuapps-retrofit-time-mode.md` | The procedure for adding time based mode to an app that already has the two button toggle. |
| `update-bar-spec.md` | The update prompt bar and the service worker rules it depends on. |

When one of these conflicts with the code, the specification is right and the
code is a bug.

### The two rules worth knowing before you touch anything

**Bump `VERSION` in `main-site/sw.js` on every deploy.** It is a plain
integer, so the bump is always +1. The browser compares the worker byte for
byte, so an unchanged constant means nobody is ever offered the new version,
however much else changed.

**A new service worker must never activate on its own.** `skipWaiting()` and
`clients.claim()` appear exactly once each, together, inside the worker's
`message` handler. Neither belongs in `install` or `activate`. A worker that
takes over silently leaves somebody running old JavaScript against new cached
assets in the middle of a session, which is the class of bug nobody can
reproduce. The update bar exists to ask first, and there is one guard worth
keeping in any test harness: **the worker's source contains no `skipWaiting()`
outside the message handler.**

### Where the app deviates from the theme specification, and why

One place, deliberately. `uwuapps-theme.md` gives the page a flat background
of `color-mix(in srgb, var(--brand) 10%, var(--bg))`, and every part of the
editor follows that. The **card canvas and the presenter do not**: they use
the full brand colour as the background in light mode and the full brand
colour as the text in dark mode.

That is the app's entire purpose rather than a style preference. A signboard
tinted to 10% is a white rectangle at ten paces. The deviation is confined to
`.card-frame` and `.present` in `style.css`, both are still derived from the
same `--brand` and mode tokens, and nothing else in the app departs from the
shared theme.

## Licence

See [LICENSE](LICENSE).
