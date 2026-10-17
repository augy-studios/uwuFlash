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
api/                Vercel functions, for the Android app only: its update check
                    (app-release.js) and "new version" notifications (push/release.js)
package.json        only says api/ is ES modules; there is nothing to install
.env.example        the variables api/ reads, which live in Vercel
.well-known/        assetlinks.json, the Android app's signing key, so links open in it
```

## The modules

| File | What it owns |
| --- | --- |
| `js/app.js` | Boot, state, and every event listener. The only module that touches the DOM of the editor. |
| `js/deck.js` | The data model: cards, layers, layouts, reordering, and reading a stored deck back safely. No DOM. |
| `js/render.js` | Drawing one card into a box. Used by both the editor preview and the presenter, which is what keeps them identical. |
| `js/store.js` | Persistence. Cards in localStorage, image blobs in IndexedDB. |
| `js/theme.js` | The theme system. Copied from `uwuapps-theme.md` with only `APP_KEY` changed. |
| `js/update.js` | Service worker registration and the update bar, which in the Android app also offers the app's own updates. |
| `js/tray.js` | The Edge Tray (`edge-tray-spec.md`): Share, Present and Theme, top right. |
| `js/icons.js` | Inline SVG icons. There are no emoji and no icon font. |
| `js/ui.js` | Icon hydration, modal open/close, HTML escaping, toasts. |
| `js/share.js`, `js/viewer.js`, `js/p2p.js`, `js/qr.js` | Sharing: the host's side and the share sheet, the other screen's side, the PeerJS pairing (`STUN-p2p-spec.md`), and the QR code. |
| `js/screen.js` | The screen while presenting, in the Android app: kept on, full brightness, full screen, the volume keys, flicks, and speaking a card. |
| `js/app-bridge.js` | The channel to the Android app (`android/`). Inert in a browser. |
| `js/app-update.js`, `js/app-notify.js` | The app's update check and its notifications bell, both in the Edge Tray. |
| `js/nearby.js` | Sharing with no wifi between phones with the app, which `p2p.js` uses beside PeerJS. |

Everything with `app-` in its name, and `screen.js` and `nearby.js`, does
nothing in a browser or the PWA: each asks `AppBridge.has()` first. See
`android/README.md`.

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
