// Notifications, in the Android app only. The bell in the Edge Tray opens a
// window with two switches, and each is an FCM topic the app joins
// (FlashPlugin.setTopic), so the server keeps no list of phones:
//
//   releases  a new version of the app, pushed by api/push/release.js when a
//             release is published on GitHub
//   news      sent by hand from the Firebase console (android/FIREBASE-SETUP.md)
//
// Turning a switch on asks Android's notification permission first (Android
// 13 and later), through Capacitor's PushNotifications plugin. Nothing is
// asked until a switch is turned on.
//
// The bell only shows when the app was built with Firebase
// (google-services.json). The website and the PWA have no notifications.

import { AppBridge } from "./app-bridge.js";
import { addTrayButton } from "./tray.js";
import { hydrateIcons, openModal, closeModal } from "./ui.js";

const NOTES = {
  denied: "Notifications are off for uwuFlash in Android's settings. Turn them on there, then come back.",
  offline: "Couldn't reach Firebase. Check you're online, then try again.",
};

const SWITCHES = [
  { topic: "releases", label: "New versions of the app", hint: "When an update is ready to install" },
  { topic: "news", label: "News from uwuFlash", hint: "Now and then: new features, and other news" },
];

const $ = (id) => document.getElementById(id);
let switches = [];

function buildModal() {
  const modal = document.createElement("div");
  modal.className = "modal-backdrop hidden";
  modal.id = "notifyModal";
  modal.innerHTML = `
    <div class="modal glass" role="dialog" aria-modal="true" aria-labelledby="notifyModalTitle">
      <div class="modal-head">
        <h2 id="notifyModalTitle">Notifications</h2>
        <button class="icon-btn small" type="button" data-close-modal="notifyModal" aria-label="Close">
          <span data-icon="close"></span>
        </button>
      </div>
      <div class="stack">
        ${SWITCHES.map(
          (s) => `
          <label class="toggle-row">
            <span class="toggle-row-text">${s.label}<small>${s.hint}</small></span>
            <input class="switch" type="checkbox" role="switch" data-topic="${s.topic}">
          </label>`
        ).join("")}
      </div>
      <p class="mode-note" id="notifyNote" hidden></p>
      <button class="btn" id="notifySettingsBtn" type="button" hidden>Open Android's settings</button>
    </div>`;
  document.body.append(modal);
  hydrateIcons(modal);

  // app.js wires the modals that ship in the page; this one is made later.
  modal.querySelector("[data-close-modal]").addEventListener("click", () => closeModal("notifyModal"));
  modal.addEventListener("click", (e) => {
    if (e.target === modal) closeModal("notifyModal");
  });
  return modal;
}

function note(text, { settings = false } = {}) {
  const p = $("notifyNote");
  p.textContent = text || "";
  p.hidden = !text;
  $("notifySettingsBtn").hidden = !settings;
}

async function allowed() {
  const now = await AppBridge.call("PushNotifications", "checkPermissions");
  if (now.receive === "granted") return true;
  // Once refused for good, Android won't prompt again: its settings are the
  // only way.
  if (now.receive === "denied") return false;
  const after = await AppBridge.call("PushNotifications", "requestPermissions");
  return after.receive === "granted";
}

async function refresh() {
  note("");
  try {
    const [topics, permission] = await Promise.all([
      AppBridge.call("Flash", "topics"),
      AppBridge.call("PushNotifications", "checkPermissions"),
    ]);
    switches.forEach((input) => {
      input.checked = Boolean(topics[input.dataset.topic]);
    });
    // Turned on here, then switched off in Android's settings: say why
    // nothing arrives.
    const anyOn = SWITCHES.some((s) => topics[s.topic]);
    if (anyOn && permission.receive !== "granted") note(NOTES.denied, { settings: true });
  } catch {
    // The switches stay as drawn.
  }
}

async function toggle(input) {
  const on = input.checked;
  input.disabled = true;
  note("");
  try {
    if (on && !(await allowed())) {
      input.checked = false;
      note(NOTES.denied, { settings: true });
      return;
    }
    await AppBridge.call("Flash", "setTopic", { topic: input.dataset.topic, on });
  } catch (cause) {
    input.checked = !on;
    note(cause?.message || NOTES.offline);
  } finally {
    input.disabled = false;
  }
}

export function initAppNotify() {
  if (!AppBridge.native) return;
  AppBridge.ready(5000).then((inApp) => {
    if (!inApp || !AppBridge.has("push")) return;

    const modal = buildModal();
    switches = [...modal.querySelectorAll("[data-topic]")];
    switches.forEach((input) => input.addEventListener("change", () => toggle(input)));

    const bell = addTrayButton({
      id: "notifyBtn",
      icon: "bell",
      label: "Notifications",
      onClick: () => {
        refresh();
        openModal("notifyModal");
      },
    });
    if (bell) {
      bell.setAttribute("aria-haspopup", "dialog");
      hydrateIcons(bell);
    }

    $("notifySettingsBtn").addEventListener("click", () => {
      AppBridge.call("Flash", "openSettings", { what: "notifications" }).catch(() => {});
    });
    // Back from Android's settings with the window still open.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible" && !modal.classList.contains("hidden")) refresh();
    });
  });
}
