# uwuFlash for Android

The Android app, `org.uwuapps.flash`. From 1.1.0 it's a Flutter app: every screen is drawn in Dart
(`lib/`), with the web app at flash.uwuapps.org as its spec. It keeps the site's storage keys, words
and sharing wire, so it reads what 1.0.0 kept and shares with the website and with phones on 1.0.0.
The native parts (`android/app/src/main/java/org/uwuapps/flash/`) are the same Java as before,
reached over a method channel (`lib/native/native_bridge.dart`, `bridge/`).

Version 1.0.0 was the site in Capacitor's WebView. 1.1.0 brings everything it kept across on its
first open (`lib/data/migrate.dart`, `MigratePlugin`). It's the same package and signing key, so it
installs over 1.0.0 as an update. The website and PWA in `main-site/` are unchanged, and keep their
`js/app-*.js` for phones still on 1.0.0.

It's shared as an APK file through GitHub Releases (see `release/README.md`), and updates itself
from there.

## The two looks

| Look | What it is | Where it's set |
|---|---|---|
| **Material You**, the default | Material 3, with the phone's own font (`config_bodyFontFamily`, `FlashPlugin.fonts`) and its wallpaper's colours on Android 12 and later (`dynamic_color`). Before Android 12, a green palette from the site's colour. Light or dark follows the phone. The signboard itself takes the wallpaper's colours too. In **Theme**, a brand colour can stand in for the wallpaper's | The **Material You** switch in **Settings** or **Theme**. `app.look` is `usual` when it's off |
| **The UwU Apps theme** | The website's look, from `uwuapps-theme.md`: the Jua font, the site's own icons, see-through glass surfaces, and the seven brand colours. Light, dark or by the clock | The same switch, off |

Material You is only in this app: the website keeps the UwU Apps theme. On another device, a screen
wears the sharing phone's colours. Another uwuFlash app is told them (`theme.card` in each
snapshot). The website can't work them out, so it wears the brand colour instead (`theme.color`).

## Where things are

| Part | Site | Dart |
|---|---|---|
| The deck, its layouts and the slots | `js/deck.js` | `lib/data/deck.dart` |
| Saving, the same keys | `js/store.js` | `lib/data/store.dart`, `images.dart`, `images_io.dart` |
| From the WebView app | | `lib/data/migrate.dart` |
| Theme | `js/theme.js`, `css/theme.css` | `lib/theme/theme.dart`, `icons.dart` |
| Buttons, panels, sheets in both looks | `style.css` | `lib/ui/kit.dart` |
| Drawing a card, and the ticker | `js/render.js`, `js/ticker.js` | `lib/card/card_view.dart`, `ticker.dart` |
| The editor and every edit | `js/app.js` | `lib/screens/editor.dart`, `lib/app/state.dart` |
| The Edge Tray | `js/tray.js`, `edge-tray-spec.md` | `lib/app/edge_tray.dart` |
| The presenter | `js/app.js` | `lib/screens/present.dart` |
| Sharing: the host and the sheet | `js/share.js` | `lib/share/share_host.dart`, `lib/screens/share_sheet.dart` |
| Sharing: the other screen | `js/viewer.js` | `lib/share/viewer.dart`, `lib/screens/viewer_screen.dart` |
| Pairing, either way | `js/p2p.js` | `lib/share/p2p.dart` |
| PeerJS's broker, data channels and BinaryPack | the PeerJS library | `lib/share/peer.dart`, `binarypack.dart` |
| Nearby | `js/nearby.js` | `lib/share/nearby.dart` |
| Updates, notifications, Settings | `js/app-update.js`, `js/app-notify.js` | `lib/screens/update_bar.dart`, `sheets.dart` |

## What only the phone can do

| Feature | Native side (`android/app/src/main/java/org/uwuapps/flash/`) | Dart side |
|---|---|---|
| **The screen stays on** while presenting, and while showing someone else's cards | `FlashPlugin.screen` | `lib/native/screen.dart` |
| **Full brightness** the moment a card is presented or shown, and back to the phone's own when it's over. Only the app's window: the phone's own setting is untouched | `FlashPlugin.screen` | the same |
| **Real full screen**, every bar hidden | `FlashPlugin.screen`, `MainActivity.applyBars` | the same |
| **Volume keys change cards** while presenting: volume down for the next card, volume up for the one before, either held to switch the card's ticker. The rest of the time they work as usual | `FlashPlugin.keys`, `MainActivity.dispatchKeyEvent` | `lib/app/state.dart` (`_onPresentKey`) |
| **Flick to change cards** while presenting: a sharp turn of the wrist to the right for the next card, to the left for the one before. Off until switched on with its button in the presenter, and remembered. Phones with a gyroscope only | `Flick`, `FlashPlugin.flick` | `lib/app/state.dart` (`togglePresentFlick`) |
| **Speak a card**: a **Speak** button under a text layer's text box opens Android's speech screen, and what you say goes onto the card on a line of its own. No microphone permission: the speech screen has its own | `FlashPlugin.listen` | `lib/screens/editor.dart` |
| **Sharing with no wifi or internet**: phones that both have the app share over Google's Nearby Connections (Bluetooth to find each other, then direct wifi between them), alongside the usual same-wifi sharing. Mirror, Extend, Big Screen and Send cards all work this way, and a phone joins whichever way connects first. Needs Google Play services on every phone | `NearbyShare`, `FlashPlugin.nearby*` | `lib/share/nearby.dart`, `p2p.dart` |
| **Updating itself** from GitHub Releases: a bar at the top of the app when a new version is out, and the Edge Tray's download button, **Check for updates**. Both use Android's own installer | `UpdateActivity` | `lib/screens/update_bar.dart`, `main-site/api/app-release.js` |
| **Notifications**, opt-in from the bell in the Edge Tray: new versions of the app (pushed the moment a release is published), and news you send from the Firebase console | `FlashPlugin.setTopic` (FCM topics), `Notifications`, `MessagingService` | `lib/screens/sheets.dart`, `main-site/api/push/release.js`, `api/_lib/fcm.js` |
| **The site's own links** (`https://flash.uwuapps.org/...`, verified by `.well-known/assetlinks.json`), so scanning a share code's QR code with the phone's camera joins in the app. Also `uwu://flash/` links, such as `uwu://flash/?join=BCD234` | `MainActivity`, `FlashPlugin.open` | `lib/app/app.dart` (`openLink`) |
| **Bringing 1.0.0's cards across**, once: a hidden WebView, never shown and the only one left, reads the site's `localStorage` and pictures with nothing fetched. The WebView's copy is left as it was, and if a picture the deck uses doesn't come, the next two launches try again | `MigratePlugin` | `lib/data/migrate.dart` |

Things the app deliberately doesn't do:

- **Keep running in the background.** Presenting and sharing need the app open, as on the web.
- **Scan QR codes itself.** The phone's camera already does, and the site's links open in the app,
  so it needs no camera permission.
- **Change the phone's brightness setting.** Only the app's own window goes to full brightness, and
  only while a card is up, so it needs no "modify system settings" permission.
- **Carry the website's analytics or ads.** Those are in the site's page, which the app no longer
  loads.

### Sharing with no wifi, in more detail

When you press **Start sharing**, the app advertises the share over Nearby as well as the usual way.
The name it advertises isn't the code but a slow hash of it (`lib/share/nearby.dart`), so a phone
nearby listening for adverts can't read the code off the air. A phone that connects has to send the
code itself, inside Nearby's encrypted connection, before a link is opened (`NearbyShare.java`).

With no internet at all, the usual way can't start, and the share goes on over Nearby alone: the
share sheet says "No internet, so only phones with the uwuFlash app nearby can join." The QR code
still draws, but it may be quicker to read the code out or type it on the other phone.

Nearby can carry at most 32 KB in one message, so a long one (a whole deck sent with **Send cards**)
goes in parts. While a slow link is still sending, the twenty-a-second snapshots are skipped rather
than piled up: the next one says everything the skipped one did. Pictures go one chunk at a time.

### Permissions

| Permission | Asked | For |
|---|---|---|
| Nearby devices (`BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, and `NEARBY_WIFI_DEVICES` on Android 13 and later) | Once, as one prompt, when you press **Start sharing**, **Join**, or **Try again**, or open a scanned share code. Never at launch, and never when the app rejoins on its own | Sharing with no wifi (`NearbyShare`). Never used to find where anyone is |
| Location, Android 12 and earlier | The same moment, instead of or beside the above. On Android 11 and earlier, location also has to be switched on | Android wants it there for finding Bluetooth devices |
| Notifications (`POST_NOTIFICATIONS`) | Only when you turn on a switch under the bell in the Edge Tray (Android 13 and later) | New versions, news |
| Install unknown apps (`REQUEST_INSTALL_PACKAGES`) | The first update | `UpdateActivity` |
| Wifi state (`ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`) | Not asked: Android grants them at install | Nearby moving to direct wifi |
| Internet | Not asked: Android grants it | Sharing, and the update check |

Keeping the screen on, the brightness, the volume keys, the gyroscope and the speech screen need no
permission. A picture is picked with Android's own file picker, which needs none either.

Refusing Nearby devices is fine: sharing over the same wifi works as before, and the share sheet
says how to allow it later. If the app ever goes on Google Play, that build has to drop
`UpdateActivity` and `REQUEST_INSTALL_PACKAGES`, since Play updates apps itself.

## The project

```text
android/
  pubspec.yaml, pubspec.lock   the app's version and Dart packages
  lib/                         every screen, and the app's logic, in Dart
  android/                     the Android Studio / Gradle project: the Java, the manifest, resources
  assets/                      the Jua font and the logo
  test/                        the Dart tests: flutter test
  e2e/                         the app in a browser, driven by Playwright (its README)
  web/                         only what the Playwright suite's build needs
  build-apk.ps1                builds the signed APK into release/<version>/
  FIREBASE-SETUP.md            setting up notifications
```

## Build the APK

From the project root, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File android\build-apk.ps1
```

That one command:

1. Refuses to go on without `android.keystore` and `keystore.properties`. It never makes a new key.
2. Runs `flutter pub get`, then builds the release APK for ARM phones, signed with that key.
3. Checks the signature against the fingerprint in `main-site/.well-known/assetlinks.json`.
4. Copies the result to `release/<version>/uwuflash-<version>.apk`, with `<version>` taken from
   `pubspec.yaml`.

It needs Flutter (on the PATH, in `FLUTTER_ROOT` or in `~\flutter`), a JDK 21 or later (it finds the
newest under Program Files, such as the JDK 24 in `C:\Program Files\Eclipse Adoptium`, or
`JAVA_HOME`) and the Android SDK (`ANDROID_HOME`, the one Bubblewrap left in `~/.bubblewrap`, or
Android Studio's in `%LOCALAPPDATA%\Android\Sdk`).

**For a new version**, raise the version in `pubspec.yaml` first:

```yaml
version: 1.2.0+3    # versionName+versionCode. A phone only updates to a higher versionCode
```

If `release/<version>/` already has an APK, the script warns and replaces it.

Without `android/app/google-services.json` the app builds and works, but has no notifications, and
the bell stays hidden. See `FIREBASE-SETUP.md`.

To try changes on a phone or an emulator, `flutter run` from `android/` with it plugged in and USB
debugging on. A debug build is signed with the debug key, so uninstall it before installing a
release APK. To try a release build on an x86 emulator, whose libraries a normal release leaves out:

```powershell
flutter build apk --release --target-platform android-x64 --android-project-arg=keepx86=true
```

## The signing key

`android\android.keystore` and `android\keystore.properties` are kept out of git, and need backing
up somewhere safe and private, such as a password manager. An APK signed with a different key can't
update one already installed, so losing them means every user has to uninstall and reinstall.

## Google's developer verification

From 30 September 2026, Android in Singapore (with Brazil, Indonesia and Thailand) checks that apps
come from a verified developer, starting with installs through participating app stores, with more
to follow in 2027. To stay ahead of it and keep Play Protect from warning about the APK:

1. Sign up on the [Android Developer Console](https://developer.android.com/developer-verification/guides/android-developer-console),
   or use the account you made for your other apps.
2. Register the package `org.uwuapps.flash` with the SHA-256 fingerprint in `assetlinks.json`.

Check [Google's guide](https://developer.android.com/developer-verification/guides) for the current
steps; they were still settling in October 2026.

## Install it

Copy the APK to the phone and open it. Android asks to allow installing apps from wherever it was
opened (Files, Chrome, Telegram); allow it once. After that, the app updates itself.

The app keeps its own storage, apart from Chrome's, so it starts with no cards even if you've made
some on the website. Use **Send cards** from the browser to the app to bring them across.

## Tests

- `flutter test` from `android/`: the deck, BinaryPack, the Nearby tag, the wall's geometry, and
  checking what other devices send. It also checks the protocol against `main-site/js/p2p.js`.
- `e2e/`: the real screens in a browser, sharing with the actual website. See its README, and what
  it can't cover.

## Checking it by hand

On a phone with the app installed:

- **First paint**: the app opens to the editor, in the phone's font and wallpaper's colours.
- **Over 1.0.0**: install 1.0.0, make cards with pictures, then install this over it. A note says
  your cards are here from before, and they are, pictures included.
- **The UwU Apps theme**: **Settings** > **Material You** off. The Jua font and the glass surfaces,
  as on the website. Back on, the phone's again.
- **Edge Tray**: Share, Present, then (with Firebase) the bell, then the circled download arrow,
  Settings and Theme, unrolling one after another. Collapse and reopen it.
- **Present**: press play. Every bar disappears, the screen goes to full brightness and stays on.
  Volume down and up change cards; hold either to switch the ticker; Back stops presenting and the
  brightness goes back to the phone's own.
- **Flick**: in the presenter, tap the flick button. Flick your wrist right and left: the cards
  change. Leave it held still or walk with it: they don't.
- **Speak**: select a text layer, tap **Speak**, say something. It appears on the card.
- **Share with no wifi**: with two phones that have the app, turn on airplane mode on both, then
  Bluetooth back on. Press **Start sharing** on one (allow Nearby devices), and join with the code on
  the other. Press play: the card shows on the other phone. Try **Big Screen** with three, and
  **Send cards**. Also with one phone on 1.0.0.
- **Share as usual**: with wifi, share to a laptop's browser. It works as it does on the website.
- **Links**: scan a share code's QR code with the phone's camera. It joins in the app, not the
  browser. If it opens the browser, `assetlinks.json` isn't deployed with this key yet.
- **Updates**: the Edge Tray's circled download arrow says you have the newest version.
- **Notifications** (with Firebase set up): see `FIREBASE-SETUP.md`, step 7.

## Changing it

- **A screen or how something works**: `lib/`. Keep the site's words, and its storage keys.
- **What's sent between devices**: `lib/share/`, and the same in `main-site/js/`. Raise
  `protocolVersion` in `lib/share/p2p.dart` and `PROTOCOL_VERSION` in `main-site/js/p2p.js` together.
- **Permissions, activities, links**: `android/app/src/main/AndroidManifest.xml`.
- **Something new the app can do natively**: a `@PluginMethod` in `FlashPlugin`, called from Dart with
  `Native.call('Flash', 'method', {...})`. Add a word to `info`'s `features`, and ask
  `Native.has('word')`.
- **Versions of Android's libraries**: `android/variables.gradle`. Dart packages: `pubspec.yaml`.
