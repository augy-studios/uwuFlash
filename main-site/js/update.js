/* Update prompt bar. See update-bar-spec.md at the repo root.

   The rule the whole design rests on: a new worker never activates on its
   own. It downloads, it installs, and then it waits. The only thing that
   promotes it is a person pressing Reload.

   In the Android app the same bar also says when a new version of the app
   itself is out (js/app-update.js), and its Update hands over to the app's
   own updater. One bar, one order: the site's new version first, as it is
   one tap and the app's turn comes straight after the reload. */

import { escapeHtml } from "./ui.js";
import { trackBanner } from "./tray.js";
import { AppBridge } from "./app-bridge.js";

const SW_URL = "/sw.js";

const COPY = {
  site: {
    label: "Update",
    ready: () => "A new version of uwuFlash is ready.",
    primary: "Reload",
  },
  app: {
    label: "App update",
    ready: (version) => `Version ${version} of the uwuFlash app is out.`,
    primary: "Update",
  },
  later: "Not now",
};

let registration = null;
let waitingWorker = null;
let reloading = false;
let dismissed = false;

// A newer Android app than the one running, { version, ... } from
// /api/app-release, and whether "Not now" was pressed on it.
let appUpdate = null;
let appDismissed = false;

function showing() {
  if (waitingWorker && !dismissed) return "site";
  if (appUpdate && !appDismissed) return "app";
  return null;
}

/* Draw or remove the bar.

   The live region is the paragraph, and it is put on the page before its text
   is. A screen reader announces a live region when its contents change, so a
   node that was never on the page without its text has nothing to compare
   against and is announced by nothing at all. Building the whole bar and then
   prepending it is the version of this that looks right and says nothing. */
function render() {
  let bar = document.querySelector(".update-notice");
  const kind = showing();

  if (!kind) {
    bar?.remove();
    trackBanner(null);
    return;
  }

  // Already up and saying this: nothing to redraw.
  if (bar?.dataset.kind === kind) return;
  // The site's bar dismissed with the app's waiting behind it: the same bar,
  // now saying the other thing.
  bar?.remove();

  const copy = COPY[kind];
  bar = document.createElement("div");
  bar.className = "update-notice";
  bar.dataset.kind = kind;
  // role="region" on the bar and role="status" on the sentence inside it.
  // Nothing is wrong, so this is never an alert: an alert interrupts a screen
  // reader mid-sentence to say a website is slightly newer than it was.
  bar.setAttribute("role", "region");
  bar.setAttribute("aria-label", copy.label);
  bar.innerHTML = `
    <div class="update-notice-inner">
      <p data-message role="status"></p>
      <button type="button" class="btn btn-primary" data-sw-update>
        ${escapeHtml(copy.primary)}
      </button>
      <button type="button" class="btn btn-quiet" data-sw-later>
        ${escapeHtml(COPY.later)}
      </button>
    </div>
  `;

  bar.querySelector("[data-sw-update]").addEventListener("click", () => {
    if (kind === "app") {
      // The app's update window downloads it, checks it, and opens Android's
      // own installer (android/.../UpdateActivity.java).
      AppBridge.call("Flash", "update", { check: false, version: appUpdate.version }).catch(() => {});
      return;
    }
    // The only place anything asks for skipWaiting. The reload happens on
    // controllerchange, not here.
    waitingWorker?.postMessage("skip-waiting");
  });

  bar.querySelector("[data-sw-later]").addEventListener("click", () => {
    // This page view only. Never stored: a reader who dismissed once would
    // otherwise never hear about an update again.
    if (kind === "app") appDismissed = true;
    else dismissed = true;
    render();
  });

  document.body.prepend(bar);
  trackBanner(bar);

  // A frame later, so the empty region is registered first and the text that
  // lands in it reads as a change.
  requestAnimationFrame(() => {
    const message = bar.querySelector("[data-message]");
    if (message) message.textContent = copy.ready(appUpdate?.version);
  });
}

/** A newer Android app is out (js/app-update.js). */
export function offerAppUpdate(latest) {
  if (appUpdate?.version === latest.version) return;
  appUpdate = latest;
  render();
}

/**
 * Asks the server for a new worker now, rather than on the browser's own
 * schedule: the Edge Tray's "Check for updates" in the app. A new one found
 * shows the bar as usual, once it has installed.
 */
export function checkSiteUpdate() {
  return registration ? registration.update().catch(() => {}) : Promise.resolve();
}

function watchForUpdate() {
  if (!registration) return;

  // A worker already waiting when the page opened. This is the ordinary case
  // on the second page view after a deploy, and without it the prompt would
  // only ever reach somebody who happened to have the page open at the moment
  // the new worker finished installing.
  if (registration.waiting && navigator.serviceWorker.controller) {
    waitingWorker = registration.waiting;
    render();
  }

  registration.addEventListener("updatefound", () => {
    const installing = registration.installing;
    if (!installing) return;

    installing.addEventListener("statechange", () => {
      // `installed` with a controller present means an update. `installed`
      // with no controller is a first install, which has nothing to prompt
      // about: there is no previous version on screen to protect.
      if (installing.state === "installed" && navigator.serviceWorker.controller) {
        waitingWorker = registration.waiting ?? installing;
        render();
      }
    });
  });
}

function registerWorker() {
  if (!("serviceWorker" in navigator)) return;

  navigator.serviceWorker
    .register(SW_URL)
    .then((reg) => {
      registration = reg;
      watchForUpdate();
    })
    .catch((cause) => {
      // A refused registration is not a reason to break the page. Private
      // browsing in some browsers, and any http origin that is not localhost,
      // land here.
      console.warn("service worker registration failed:", cause);
    });

  // The swap, once somebody has accepted it. Reloading here rather than in
  // the click handler is what makes the page come back on the new version:
  // the controller has changed by this point, so the reload is served by the
  // new worker and not the one being replaced.
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (reloading) return;
    reloading = true;
    window.location.reload();
  });
}

export function initUpdateBar() {
  // Registration on `load`, not immediately: installing fetches everything
  // the worker precaches, and starting that while the page is still fetching
  // its own assets is how a service worker makes a first visit slower for no
  // gain.
  if (document.readyState === "complete") registerWorker();
  else window.addEventListener("load", registerWorker, { once: true });
}
