# uwuFlash, main-site

The app itself. Static files, no build step: what is in this folder is what is
served. Open `index.html` through any web server and it runs.

```text
index.html          the whole interface, one page
style.css           app styles, imports css/theme.css
css/theme.css       the uwuapps theme system, unmodified
js/                 ES modules, loaded by index.html as type="module"
sw.js               the service worker
404.html, 404.css   the not found page, with its own fixed palette
api/                Vercel serverless functions, unused by this app
```

## The modules

| File | What it owns |
| --- | --- |
| `js/app.js` | Boot, state, and every event listener. The only module that touches the DOM of the editor. |
| `js/deck.js` | The data model: cards, layers, layouts, reordering, and reading a stored deck back safely. No DOM. |
| `js/render.js` | Drawing one card into a box. Used by both the editor preview and the presenter, which is what keeps them identical. |
| `js/store.js` | Persistence. Cards in localStorage, image blobs in IndexedDB. |
| `js/theme.js` | The theme system. Copied from `uwuapps-theme.md` with only `APP_KEY` changed. |
| `js/update.js` | Service worker registration and the update bar. |
| `js/icons.js` | Inline SVG icons. There are no emoji and no icon font. |
| `js/ui.js` | Icon hydration, modal open/close, HTML escaping, toasts. |

The dependency direction is one way: `app.js` imports everything, `deck.js`
imports nothing. Nothing imports `app.js`.

## Running it

Any static server works. The service worker needs `localhost` or https, so
opening `index.html` as a `file://` URL gives you the app without the worker.

```sh
npx http-server main-site -p 8080
```

## Deploying

**Bump `VERSION` in `sw.js` on every deploy.** It is a plain integer, so the
bump is always +1:

```js
const VERSION = 2;   ->   const VERSION = 3;
```

The browser compares `sw.js` byte for byte. If this constant does not change,
no update is detected however much else moved, and nobody is ever offered the
new version. Treat forgetting it as a build error rather than a habit.

When you add a file that the app loads, add it to `ASSETS` in `sw.js` too, or
it will be missing for anybody offline.

## Two things that are easy to break

**Never add `skipWaiting()` to `install` or `clients.claim()` to `activate`.**
They appear exactly once each, inside the `message` handler, and that is the
whole of the update design: a new worker waits until somebody presses Reload.
Adding either to `install` is the one-line change that silently turns the
update bar back into a mid-session takeover. See the root README.

**The two hours in the pre-paint script are duplicated on purpose.**
`index.html` and `404.html` each carry a copy of the 09:00 and 18:00 boundary
that `js/theme.js` also defines, because that script runs before first paint
and cannot import anything. Change all three together.
