# The app in a browser, driven by Playwright

The real Flutter screens, built for the web from `main_e2e.dart`, with a stand-in for the Java
side. It's for testing only: the website is still the HTML site in `main-site/`, and this build
never ships.

```powershell
cd android\e2e
npm install
npx playwright install chromium
npm run build      # flutter build web, into android/build/web
npm test
```

`serve.mjs` serves that build on port 4173 and the real website on port 4174. Playwright starts it
by itself.

| Tests | What they cover |
|---|---|
| `editor.spec.js` | Words, layers, pictures and the crop, cards, the ticker, wrapping, the Edge Tray, the update bar, scanned share codes, notifications. |
| `theme.spec.js` | Material You by default in the phone's colours, Settings switching it off for the UwU Apps theme, brand colours and modes. |
| `present.spec.js` | The presenter: holding the screen, tap, swipe and keyboard, the volume keys, flick, the ticker. |
| `share.spec.js` | Sharing with the actual website both ways round and with another copy of the app, over the real PeerJS broker and WebRTC: Mirror, Extend, Big Screen, Send cards. It needs the internet. |

Things are found the way a screen reader finds them (Flutter's semantics tree), so a test that
can't find a button usually means TalkBack can't either. Screenshots land in
`test-results/shots/`.

`compare-site.mjs`, with `serve.mjs` running, draws the same cards on the real website and in the app
into `test-results/compare/`, for checking layouts by eye.

## What it can't cover

Playwright drives a browser, so everything only a phone has is checked as far as the call to the
Java side, not beyond: the volume keys and flicks are sent in with `window.e2eEmit`, and calls such
as `Flash.screen` are read from `window.e2eCalls`. For the rest, use a phone or an emulator
(`../README.md`, "Checking it by hand"): the real wallpaper colours and font, Nearby between two
phones, notifications, updating, and bringing cards across from 1.0.0.
