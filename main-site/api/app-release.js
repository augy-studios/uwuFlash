/* GET /api/app-release   the newest release of the Android app (android/)

   For its update bar (js/app-update.js) and its own updater
   (UpdateActivity.java). Cached at Vercel's edge, so GitHub sees a request
   every ten minutes however many phones ask.

     { version, apk, size, sha256, page, date, summary, notes } (api/_lib/release.js),
     and history: every release, this one first, each
     { version, date, summary, notes, page }, for the updater's changelog; or
     { version: null, history: [] } while there is no release with an APK.

   ?v=<version> is ignored here, but makes a URL the cache hasn't seen: the
   app adds it when a "new version is out" notification is tapped, so the
   release just published is read now. */

import { allReleases } from "./_lib/release.js";

export default async function handler(req, res) {
  let releases;
  try {
    releases = await allReleases();
  } catch (cause) {
    console.error("[uwuflash] app-release:", cause.message);
    res.setHeader("Cache-Control", "no-store");
    return res.status(502).json({ error: "Couldn't reach GitHub" });
  }

  const history = releases.map(({ version, date, summary, notes, page }) => ({ version, date, summary, notes, page }));
  res.setHeader("Cache-Control", "public, s-maxage=600, stale-while-revalidate=3600");
  return res.status(200).json(releases[0] ? { ...releases[0], history } : { version: null, history });
}
