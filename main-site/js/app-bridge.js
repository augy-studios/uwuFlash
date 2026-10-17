// The channel to the Android app (android/), when the site is open in it:
// what the app can do for the page that a web page can't do for itself. The
// app is Capacitor: the site runs in its own WebView, which injects
// window.Capacitor before the page's scripts, and calls go straight to its
// plugin (android/native/app/src/main/java/org/uwuapps/flash/FlashPlugin.java).
//
// In a browser or the PWA there's no window.Capacitor, and the page carries on
// as a website with everything it already has.
//
//   AppBridge.native                    true in the app
//   AppBridge.has("screen")             whether the app says it can
//   AppBridge.ready(ms)                 resolves true once the app has answered, false after ms
//   AppBridge.call(plugin, method, {})  a plugin's answer
//   AppBridge.listen(plugin, name, fn)  fn(data) each time the plugin says name; { remove() }
//   AppBridge.version()                 the app's version, such as "1.0.0"
//
// Every app-only feature asks has(), never native alone: the site deploys
// ahead of the app, and an older app lacks what a newer one has.
//
// Also, in the app: the status bar's icons follow the page's light or dark
// mode, not the phone's, and there's no status bar to leave room for
// (data-statusbar="hidden", set before first paint by the head script in
// index.html from the user agent, and again here).

const cap = window.Capacitor;
const native = Boolean(cap && typeof cap.nativePromise === "function" && cap.getPlatform?.() === "android");

let info = null;
const waiting = [];

function call(plugin, method, options = {}) {
  return native ? cap.nativePromise(plugin, method, options) : Promise.reject(new Error("Not in the app."));
}

// Capacitor's own bridge has addListener on window.Capacitor. Outside the
// app, nothing is ever said.
function listen(plugin, name, fn) {
  const none = { remove() {} };
  if (!native || typeof cap.addListener !== "function") return none;
  try {
    const handle = cap.addListener(plugin, name, (data, err) => {
      if (!err) fn(data);
    });
    return { remove: () => handle?.remove?.() };
  } catch {
    // An app too old to say it: the page carries on without hearing.
    return none;
  }
}

function heard(answer) {
  info = answer;
  waiting.splice(0).forEach((resolve) => resolve(true));
}

function ready(ms = 1500) {
  if (info) return Promise.resolve(true);
  if (!native) return Promise.resolve(false);
  return new Promise((resolve) => {
    waiting.push(resolve);
    setTimeout(() => resolve(false), ms);
  });
}

// The site picks light or dark itself (js/theme.js), whatever the phone is
// set to, so the status bar's icons are told which: dark icons on the light
// page, light on the dark.
function syncBars() {
  const style = document.documentElement.getAttribute("data-mode") === "dark" ? "DARK" : "LIGHT";
  call("SystemBars", "setStyle", { style }).catch(() => {});
}

if (native) {
  document.documentElement.setAttribute("data-app", "android");
  // From the user agent, not Flash.info, so the page is laid out right from
  // the start. Every build so far (uwuFlashApp/1) hides the bar.
  const build = Number(/uwuFlashApp\/(\d+)/.exec(navigator.userAgent)?.[1] || 0);
  if (build >= 1) document.documentElement.setAttribute("data-statusbar", "hidden");
  call("Flash", "info")
    .then(heard)
    .catch(() => heard({ features: [] }));

  syncBars();
  new MutationObserver(syncBars).observe(document.documentElement, { attributes: true, attributeFilter: ["data-mode"] });
}

export const AppBridge = {
  native,
  has: (feature) => Boolean(info?.features?.includes(feature)),
  ready,
  call,
  listen,
  version: () => info?.version || null,
};
