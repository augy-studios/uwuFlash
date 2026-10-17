# uwuFlash for Android

The Android app, `org.uwuapps.flash`: the web app at flash.uwuapps.org in
[Capacitor](https://capacitorjs.com)'s WebView (`capacitor.config.json`, `server.url`). The
site's own updates reach it at once, so the app only needs building again for its native parts.
Those are the things a web page can't do, which the page reaches through Capacitor's bridge
(`main-site/js/app-bridge.js`).

It's shared as an APK file through GitHub Releases (see `release/README.md`), and updates
itself from there.

## What it adds to the site

| Feature | Native side (`native/app/src/main/java/org/uwuapps/flash/`) | Site side (`main-site/`) |
|---|---|---|
| **The screen stays on** while presenting, and while showing someone else's cards. In Chrome the page uses the Screen Wake Lock API, which Android's WebView doesn't have | `FlashPlugin.screen` | `js/screen.js`, `js/app.js` (`enterPresent`), `js/viewer.js` (`holdViewerScreen`) |
| **Full brightness** the moment a card is presented or shown, and back to the phone's own when it's over. A web page can't set the brightness at all. Only the app's window: the phone's own setting is untouched | `FlashPlugin.screen` | the same |
| **Real full screen**, every bar hidden. The WebView's Fullscreen API leaves full screen the moment it's asked, which would close the presenter as it opened; the app hides the bars itself instead, and the other screen's **Full screen** button does the same | `FlashPlugin.screen`, `MainActivity.applyBars` | the same |
| **Volume keys change cards** while presenting: volume down for the next card, volume up for the one before, either held to switch the card's ticker. **Back** stops presenting. The rest of the time they work as usual. The WebView never sees these keys | `FlashPlugin.keys`, `MainActivity.dispatchKeyEvent` | `js/screen.js` (`captureKeys`), `js/app.js` (`onPresentKey`) |
| **Flick to change cards** while presenting: a sharp turn of the wrist to the right for the next card, to the left for the one before. Off until switched on with its button in the presenter, and remembered. Phones with a gyroscope only | `Flick`, `FlashPlugin.flick` | `js/screen.js` (`watchFlick`), `js/app.js` (`togglePresentFlick`) |
| **Speak a card**: a **Speak** button under a text layer's text box opens Android's speech screen, and what you say goes onto the card on a line of its own. No microphone permission: the speech screen has its own | `FlashPlugin.listen` | `js/app.js` (`renderInspector`) |
| **Sharing with no wifi or internet**: phones that both have the app share over Google's Nearby Connections (Bluetooth to find each other, then direct wifi between them), alongside the usual same-wifi sharing. Mirror, Extend, Big Screen and Send cards all work this way, and a phone joins whichever way connects first. Needs Google Play services on every phone | `NearbyShare`, `FlashPlugin.nearby*` | `js/nearby.js`, `js/p2p.js`, `js/share.js`, `js/viewer.js` |
| **Updating itself** from GitHub Releases: a bar at the top of the page when a new version is out, and the Edge Tray's download button, **Check for updates**, which also checks for a new site version. Both use Android's own installer | `UpdateActivity` | `js/app-update.js`, `js/update.js`, `api/app-release.js` |
| **Notifications**, opt-in from the bell in the Edge Tray: new versions of the app (pushed the moment a release is published), and news you send from the Firebase console | `FlashPlugin.setTopic` (FCM topics), `Notifications`, Capacitor's PushNotifications | `js/app-notify.js`, `api/push/release.js`, `api/_lib/fcm.js` |
| **The site's own links** (`https://flash.uwuapps.org/...`, verified by `.well-known/assetlinks.json`), so scanning a share code's QR code with the phone's camera joins in the app. Also `uwu://flash/` links, such as `uwu://flash/?join=BCD234` | `MainActivity` | none |
| **No status bar**, so the page has the whole screen; a swipe down from the top shows it for a moment, its icons following the page's light or dark mode, not the phone's. The user agent's `uwuFlashApp/1` tells the page there's no bar to leave room for | `MainActivity`, Capacitor's SystemBars | `index.html` (head script), `js/app-bridge.js`, `style.css` (`data-statusbar`) |

The website and PWA lose nothing: everything a browser can do stays as it was, and these only
switch on when the page is running in the app and the app says it can (`info().features`). The
bell, the update button, **Speak** and the flick button are made or shown by the page only in
the app, so a browser never sees them.

Whenever a page starts loading, the app puts the screen, the keys, the flick sensor and any
Nearby connections back as they were, so a reload in the middle of presenting never leaves the
volume keys caught or the screen held on.

Things the app deliberately doesn't do:

- **Keep running in the background.** Presenting and sharing need the app open, as on the web.
- **Scan QR codes itself.** The phone's camera already does, and the site's links open in the
  app, so it needs no camera permission.
- **Change the phone's brightness setting.** Only the app's own window goes to full brightness,
  and only while a card is up, so it needs no "modify system settings" permission.

### Sharing with no wifi, in more detail

When you press **Start sharing**, the app advertises the share over Nearby as well as the usual
way. The name it advertises isn't the code but a slow hash of it (`js/nearby.js`), so a phone
nearby listening for adverts can't read the code off the air. A phone that connects has to send
the code itself, inside Nearby's encrypted connection, before the page hears of it
(`NearbyShare.java`).

With no internet at all, the usual way can't start, and the share goes on over Nearby alone: the
share sheet says "No internet, so only phones with the uwuFlash app nearby can join." The QR
code needs the internet to draw, so read the code out or type it on the other phone.

Nearby can carry at most 32 KB in one message, so a long one (a whole deck sent with **Send
cards**) goes in parts. While a slow link is still sending, the twenty-a-second snapshots are
skipped rather than piled up: the next one says everything the skipped one did. Pictures go one
chunk at a time.

### Permissions

| Permission | Asked | For |
|---|---|---|
| Nearby devices (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, and `NEARBY_WIFI_DEVICES` on Android 13 and later) | Once, as one prompt, when you press **Start sharing**, **Join**, or **Try again**, or open a scanned share code. Never at launch, and never when a reload rejoins on its own | Sharing with no wifi (`NearbyShare`). Never used to find where anyone is |
| Location, Android 12 and earlier | The same moment, instead of or beside the above. On Android 11 and earlier, location also has to be switched on | Android wants it there for finding Bluetooth devices |
| Notifications (`POST_NOTIFICATIONS`) | Only when you turn on a switch under the bell in the Edge Tray (Android 13 and later) | New versions, news |
| Install unknown apps (`REQUEST_INSTALL_PACKAGES`) | The first update | `UpdateActivity` |
| Wifi state (`ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`) | Not asked: Android grants them at install | Nearby moving to direct wifi |
| Internet | Not asked: Android grants it | The site itself |

Keeping the screen on, the brightness, the volume keys, the gyroscope and the speech screen need
no permission.

Refusing Nearby devices is fine: sharing over the same wifi works as before, and the share
sheet says how to allow it later. If the app ever goes on Google Play, that build has to drop
`UpdateActivity` and `REQUEST_INSTALL_PACKAGES`, since Play updates apps itself.

## The project

```text
android/
  package.json, package-lock.json   Capacitor and its push plugin, pinned exactly
  capacitor.config.json             the site's address, the user agent, where the native project is
  www/offline.html                  shown when the site can't load at all (first launch offline)
  native/                           the Android Studio / Gradle project
  build-apk.ps1                     builds the signed APK into release/<version>/
  FIREBASE-SETUP.md                 setting up notifications
```

`npx cap sync android`, which the build script runs, copies `www/` and the config into
`native/` and links the plugins from `node_modules`. What it writes is kept out of git.

## Build the APK

From the project root, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File android\build-apk.ps1
```

That one command:

1. On the very first run, makes the signing key (`android.keystore` and `keystore.properties`)
   and writes its fingerprint into `main-site/.well-known/assetlinks.json`, replacing the
   template's placeholder.
2. Installs the npm packages if they're missing, and runs `npx cap sync android`.
3. Builds the release APK with Gradle, signed with that key.
4. Checks the signature against the fingerprint in `assetlinks.json`.
5. Copies the result to `release/<version>/uwuflash-<version>.apk`, with `<version>` taken
   from `versionName` in `native/app/build.gradle` (1.0.0 to start with).

(`npm run build` from inside `android/` runs the same script.)

It needs a JDK 21 or later (it finds the newest under Program Files, such as the JDK 24 in
`C:\Program Files\Eclipse Adoptium`, or `JAVA_HOME`) and the Android SDK (`ANDROID_HOME`, the
one Bubblewrap left in `~/.bubblewrap`, or Android Studio's in `%LOCALAPPDATA%\Android\Sdk`).
Gradle fetches any SDK platform it's missing.

**For a new version**, raise both of these in `native/app/build.gradle` first:

```groovy
versionCode 2          // a whole number, one higher each release: phones only update to a higher one
versionName "1.1.0"    // what people see, and the release folder's name
```

If `release/<version>/` already has an APK, the script warns and replaces it.

Without `native/app/google-services.json` the app builds and works, but has no notifications,
and the bell stays hidden. See `FIREBASE-SETUP.md`.

To try changes on a phone over USB, open `native/` in Android Studio and run it, or use
`native\gradlew.bat installDebug` with the phone plugged in and USB debugging on. A debug build
is signed with Android Studio's debug key, so uninstall it before installing a release APK.

## The first build: back up the key

The first build prints the new key's fingerprint and asks for two things:

1. **Back up `android\android.keystore` and `android\keystore.properties`** somewhere safe and
   private, such as a password manager. Both are kept out of git. An APK signed with a
   different key can't update one already installed, so losing them means every user has to
   uninstall and reinstall.
2. **Commit and deploy `main-site/.well-known/assetlinks.json`**. It lists this key's
   fingerprint, which is what lets the site's links, and so a scanned share code, open in the
   app.

From then on, the script refuses to build if the keystore is missing (restore it from your
backup), and refuses an APK signed with any key other than the one `assetlinks.json` names.

## Google's developer verification

From 30 September 2026, Android in Singapore (with Brazil, Indonesia and Thailand) checks that
apps come from a verified developer, starting with installs through participating app stores,
with more to follow in 2027. To stay ahead of it and keep Play Protect from warning about the
APK:

1. Sign up on the [Android Developer Console](https://developer.android.com/developer-verification/guides/android-developer-console),
   or use the account you made for your other apps.
2. Register the package `org.uwuapps.flash` with the SHA-256 fingerprint in
   `assetlinks.json`.

Check [Google's guide](https://developer.android.com/developer-verification/guides) for the
current steps; they were still settling in October 2026.

## Install it

Copy the APK to the phone and open it. Android asks to allow installing apps from wherever it
was opened (Files, Chrome, Telegram); allow it once. After that, the app updates itself.

The app keeps its own storage, apart from Chrome's, so it starts with no cards even if you've
made some on the website. Use **Send cards** from the browser to the app to bring them across.

## Checking it by hand

On a phone with the app installed:

- **First paint**: the app opens to the editor with no white flash, in the phone's light and
  dark modes, with no status bar. Swipe down from the top: the status bar shows, and its icons
  match the page's mode after switching theme in the Edge Tray.
- **Edge Tray**: Share, Present and Theme, then (with Firebase) the bell and the circled
  download arrow above Theme, unrolling one after another. Collapse and reopen it.
- **Present**: press play. Every bar disappears, the screen goes to full brightness and stays on.
  Volume down and up change cards; hold either to switch the ticker; Back stops presenting and
  the brightness goes back to the phone's own.
- **Flick**: in the presenter, tap the flick button (the phone with arrows). Flick your wrist
  right and left: the cards change. Leave it held still or walk with it: they don't.
- **Speak**: select a text layer, tap **Speak**, say something. It appears on the card.
- **Share with no wifi**: with two phones that have the app, turn on airplane mode on both, then
  Bluetooth back on. Press **Start sharing** on one (allow Nearby devices), and join with the
  code on the other. Press play: the card shows on the other phone. Try **Big Screen** with
  three, and **Send cards**.
- **Share as usual**: with wifi, share to a laptop's browser. It works as it does on the website.
- **Links**: scan a share code's QR code with the phone's camera. It joins in the app, not the
  browser. If it opens the browser, `assetlinks.json` isn't deployed with this key yet.
- **Updates**: the Edge Tray's circled download arrow says you have the newest version.
- **Offline first launch**: install, turn on airplane mode, open: the "No connection" page. Open
  once online, then offline again: the editor opens.
- **Notifications** (with Firebase set up): see `FIREBASE-SETUP.md`, step 7.
- **The website**: open flash.uwuapps.org in Chrome. No bell, no update button, no Speak, no
  flick button, and everything else as before.

## Changing it

- **The site's address, the user agent, the status bars**: `capacitor.config.json`, then
  `npx cap sync android`.
- **Permissions, activities, links**: `native/app/src/main/AndroidManifest.xml`.
- **Something new the page can ask the app for**: a `@PluginMethod` in `FlashPlugin`, called
  from the page with `AppBridge.call("Flash", "method", {...})`. Add a word to `info`'s
  `features` so the page can tell builds with it from builds without, and gate the page's side
  on `AppBridge.has("word")`.
- **A Capacitor plugin from npm**: `npm install` it here, then `npx cap sync android`; the page
  reaches it the same way.
- **Upgrading Capacitor**: raise the `@capacitor/*` versions in `package.json` together (the
  push plugin's numbers run on their own, so take its newest for that Capacitor), `npm install`,
  `npx cap sync android`, and compare `native/` with a fresh `npx cap add android` for template
  changes.
- **Nearby Connections** is held at 19.3.0 (`native/variables.gradle`): 19.5 is built with a
  newer Kotlin than this build reads, and 19.4 needs core library desugaring.

`npm audit` reports moderate advisories through `@capacitor/cli`'s iOS tooling. It's a
build-time tool that never reaches the app, and the suggested fix downgrades Capacitor, so leave
it until Capacitor updates it.
