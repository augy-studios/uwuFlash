# Releases

The Android app, each version in a folder of its own:

```text
release/1.0.0/
  uwuflash-1.0.0.apk      Android     android\build-apk.ps1
```

The APKs (a few MB each) are committed alongside the code they were built from. The signing
key that made them never is: see `android/README.md`.

Share them through a **GitHub Release**, where anyone can download them from
<https://github.com/augy-studios/uwuFlash/releases>.

## Build it

In PowerShell, from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File android\build-apk.ps1
```

It puts the APK in `release\<version>\uwuflash-<version>.apk`, the version taken from
`versionName` in `android/native/app/build.gradle`. For a new version, raise `versionCode` and
`versionName` there first (`android/README.md`, "Build the APK"), or phones with the old one
won't take it as an update.

## Put it on GitHub

1. **Deploy the site first** if this release needs anything new from it. The update bar, the
   Edge Tray's buttons and everything the app adds are switched on by the site.
2. Commit and push your changes, the new APK included, so the release points at the code it
   was built from.
3. Open <https://github.com/augy-studios/uwuFlash/releases/new>.
4. **Choose a tag**: type a new one, such as `android-v1.0.0`, and pick
   **Create new tag: android-v1.0.0 on publish**. Leave the target as `main`. Keep to
   `android-v<version>`: it's how the app's updater finds its releases.
5. **Release title**: `uwuFlash 1.0.0`.
6. **Describe this release**: the release notes, written as `android-app-spec.md` (section
   4.5) describes, for the people installing it.
7. Drag in the APK from `release\<version>\` to the box that says **Attach binaries by
   dropping them here or selecting them**. Wait for it to finish uploading.
8. Tick **Set as the latest release**, then **Publish release**.

`https://github.com/augy-studios/uwuFlash/releases/latest` always points at the newest one: a
good link to share. GitHub also adds the source code as zips; those are fine to leave.

## How phones hear about it

Within about 10 minutes of publishing, the app offers the new version in a bar at the top of
the page. The bar comes from the site, which reads the releases through
`main-site/api/app-release.js`. It skips drafts, pre-releases, tags that don't start
`android-v`, and releases whose APK hasn't finished uploading. **Update** downloads the APK in
the app, checks it against GitHub's checksum and hands it to Android's installer
(`UpdateActivity.java`). The Edge Tray's circled download arrow, **Check for updates**, looks at
any time.

With Firebase set up (`android/FIREBASE-SETUP.md`), phones that turned on **New versions of the
app** under the bell also get a notification the moment a release is published, even with the
app closed: GitHub calls the site (a webhook, `main-site/api/push/release.js`), which pushes it
through Firebase. That's why the APK has to be attached **before** you click **Publish
release**: a release without its APK is skipped, and the webhook isn't called again.

## Before you share it

- **Back up the signing key** after the first build (`android/README.md`, "The first build").
- **Commit and deploy `main-site/.well-known/assetlinks.json`** after the first build, so the
  site's links open in the app.
- **The repository has to be public** for others to download it. It is.
- **Never upload `android.keystore`, `keystore.properties`, `google-services.json` or
  Firebase's service account key.** Only the APK.

## If something goes wrong

| What happens | What to do |
|---|---|
| "App not installed" on the phone | An older copy signed with a different key is installed, such as a debug build or one from PWABuilder. Uninstall uwuFlash, then install again. |
| "App not installed as package appears to be invalid" | The download didn't finish. Download it again. |
| Play Protect warns about the app | See "Google's developer verification" in `android/README.md`. Until then, **More details** > **Install anyway**. |
| You uploaded the wrong file | On the release, **Edit**, delete the file with the bin icon, attach the right one, **Update release**. The app checks the file is newer and matches GitHub's checksum, so phones won't install a mismatch. |
| No update bar in the app | The tag doesn't start `android-v`, the release is a draft or pre-release, or it's been under 10 minutes. `https://flash.uwuapps.org/api/app-release` shows what phones see. |
| No "new version" notification on phones | Open the webhook in GitHub (**Settings** > **Webhooks**) and look at **Recent Deliveries**: the answer says why (`android/FIREBASE-SETUP.md`, "If something goes wrong"). Published before the APK finished uploading? **Redeliver** it now. |
