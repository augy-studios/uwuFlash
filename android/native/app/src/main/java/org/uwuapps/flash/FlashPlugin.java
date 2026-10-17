/*
 * The app itself, to the page (main-site/js/app-bridge.js):
 *
 *   info()                    { version, versionCode, features, android }: what this app can do.
 *                             Features are only listed when they'll work on this phone
 *   screen({ awake, bright, immersive })  the screen while presenting or showing shared cards:
 *                             kept on (the WebView has no Screen Wake Lock), at full brightness
 *                             (a web page can't set it at all; this app's window only, the phone's
 *                             own setting is untouched), and every bar hidden (the WebView's
 *                             Fullscreen API leaves full screen the moment it's asked). Each one
 *                             as given; false puts it back
 *   keys({ on })              while on, the volume keys and Back come to the page as "key" { key }:
 *                             "next" (volume down), "previous" (volume up), "hold" (either held),
 *                             "back". Off, they do what they always do
 *   flick({ on })             while on, a flick of the wrist comes to the page as "flick"
 *                             { direction }: 1 for a turn to the right, -1 to the left (Flick)
 *   listen({ prompt })        Android's own speech screen: { text }, or rejects "cancelled" or
 *                             "unavailable". No microphone permission: the speech screen has its own
 *   update({ check, version })  the update window (UpdateActivity): check, the Edge Tray's
 *                             "Check for updates", looks first and asks before downloading
 *   topics()                  { releases, news }: which notifications you've turned on
 *   setTopic({ topic, on })   turns "releases" (new versions) or "news" on or off, as FCM topic
 *                             subscriptions, so the server needs no list of phones
 *   openSettings({ what })    the app's notification settings ("notifications"), Bluetooth's
 *                             ("bluetooth"), or the app's page in Android's settings ("app")
 *
 * Sharing with no wifi (NearbyShare), used by main-site/js/nearby.js:
 *
 *   nearbyHost({ code, tag, ask })  advertise this share. { state }: "ready", "needs-permission"
 *                             (call again with ask, from a button), "denied", "bt-off",
 *                             "location-off", "unsupported" (no Play services), or "failed" with
 *                             a message
 *   nearbyStop()              stop advertising, and hang up on every screen that joined that way
 *   nearbyJoin({ code, tag, ask })  look for that share and connect. { state }: "searching", or one
 *                             of the refusals above. A link that opens says "nearbyOpen"
 *   nearbyLeave()             stop looking, and hang up
 *   nearbySend({ link, data })  one message on an open link: { id }, reported as "nearbySent"
 *                             { link, id, ok } once it's gone. Rejects for a link that isn't open,
 *                             or a message over 32 KB
 *   nearbyClose({ link })     hang up on one link
 *
 *   Says: "nearbyOpen" { link }, "nearbyData" { link, data }, "nearbyClosed" { link },
 *   "nearbySent" { link, id, ok }. Ids are strings: Nearby's are larger than a page's numbers hold.
 *
 * Whenever a page starts loading, everything here goes back to how it was: a reload mid-way
 * through presenting mustn't leave the volume keys caught or the screen held on.
 */
package org.uwuapps.flash;

import android.app.Activity;
import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.speech.RecognizerIntent;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.WebView;

import androidx.activity.result.ActivityResult;
import androidx.core.location.LocationManagerCompat;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.WebViewListener;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.google.firebase.FirebaseApp;
import com.google.firebase.messaging.FirebaseMessaging;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.regex.Pattern;

// Sharing with no wifi needs the Bluetooth permissions on Android 12 and later, which share one
// "Nearby devices" prompt with nearby wifi (13 and later), and location on Android 12 and before
// (nearbyPermissions).
@CapacitorPlugin(
        name = "Flash",
        permissions = {
                @Permission(alias = "nearbyWifi", strings = {Manifest.permission.NEARBY_WIFI_DEVICES}),
                @Permission(alias = "location", strings = {
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                }),
                @Permission(alias = "bluetooth", strings = {
                        Manifest.permission.BLUETOOTH_SCAN,
                        Manifest.permission.BLUETOOTH_ADVERTISE,
                        Manifest.permission.BLUETOOTH_CONNECT,
                }),
        }
)
public class FlashPlugin extends Plugin {
    // FCM topics are shared by every app in the UwU Apps Firebase project, hence the prefix. The
    // server sends new versions to uwuflash-releases (main-site/api/push/release.js); news goes
    // to uwuflash-news from the Firebase console (android/FIREBASE-SETUP.md).
    private static final String TOPIC_PREFIX = "uwuflash-";
    private static final String PREFS = "uwuflash";
    // A share code (main-site/js/p2p.js), and the page's hash of it (js/nearby.js).
    private static final Pattern CODE = Pattern.compile("[BCDFGHJKLMNPQRSTVWXYZ2-9]{6}");
    private static final Pattern TAG = Pattern.compile("[0-9a-f]{16}");
    private static final Pattern LINK = Pattern.compile("[A-Za-z0-9]{1,16}");

    private static WeakReference<FlashPlugin> sCurrent = new WeakReference<>(null);

    private volatile boolean keys;
    private NearbyShare nearby;
    private Flick flick;

    /** The plugin of the page on screen, for MainActivity's keys; null before it's loaded. */
    static FlashPlugin current() {
        return sCurrent.get();
    }

    @Override
    public void load() {
        super.load();
        sCurrent = new WeakReference<>(this);
        flick = Flick.create(getContext());
        if (NearbyShare.available(getContext())) {
            nearby = new NearbyShare(getContext(), new NearbyShare.Events() {
                @Override
                public void open(String link) {
                    JSObject data = new JSObject();
                    data.put("link", link);
                    notifyListeners("nearbyOpen", data);
                }

                @Override
                public void data(String link, String text) {
                    JSObject data = new JSObject();
                    data.put("link", link);
                    data.put("data", text);
                    notifyListeners("nearbyData", data);
                }

                @Override
                public void closed(String link) {
                    JSObject data = new JSObject();
                    data.put("link", link);
                    notifyListeners("nearbyClosed", data);
                }

                @Override
                public void sent(String link, long id, boolean ok) {
                    JSObject data = new JSObject();
                    data.put("link", link);
                    data.put("id", Long.toString(id));
                    data.put("ok", ok);
                    notifyListeners("nearbySent", data);
                }
            });
        }
        getBridge().addWebViewListener(new WebViewListener() {
            @Override
            public void onPageStarted(WebView webView) {
                reset();
            }
        });
    }

    @PluginMethod
    public void info(PluginCall call) {
        JSObject out = new JSObject();
        try {
            PackageInfo info = getContext().getPackageManager().getPackageInfo(getContext().getPackageName(), 0);
            out.put("version", info.versionName);
            out.put("versionCode", Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ? info.getLongVersionCode() : info.versionCode);
        } catch (PackageManager.NameNotFoundException e) {
            out.put("version", null);
        }
        JSArray features = new JSArray();
        features.put("screen"); // screen(): kept on, full brightness, every bar hidden
        features.put("keys"); // keys(): the volume keys and Back while presenting
        features.put("settings");
        features.put("update"); // UpdateActivity, for the update bar
        features.put("checkupdate"); // UpdateActivity's check, for the Edge Tray
        if (flick != null) features.put("flick"); // Flick: phones with a gyroscope
        if (speechAvailable()) features.put("listen"); // Android's speech screen
        if (nearby != null) features.put("nearby"); // NearbyShare: phones with Play services
        // Firebase is set up for this build (google-services.json): notifications can come.
        if (firebaseReady()) features.put("push");
        out.put("features", features);
        out.put("android", Build.VERSION.SDK_INT);
        call.resolve(out);
    }

    /* ---- presenting ---- */

    @PluginMethod
    public void screen(PluginCall call) {
        boolean awake = Boolean.TRUE.equals(call.getBoolean("awake", false));
        boolean bright = Boolean.TRUE.equals(call.getBoolean("bright", false));
        boolean immersive = Boolean.TRUE.equals(call.getBoolean("immersive", false));
        Activity activity = getActivity();
        activity.runOnUiThread(() -> {
            applyScreen(activity, awake, bright, immersive);
            call.resolve();
        });
    }

    // For this app's window only: Android puts the phone's own brightness and screen timeout
    // back by itself whenever the app isn't on screen.
    private static void applyScreen(Activity activity, boolean awake, boolean bright, boolean immersive) {
        Window window = activity.getWindow();
        if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        WindowManager.LayoutParams attrs = window.getAttributes();
        attrs.screenBrightness = bright ? WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
                : WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE;
        window.setAttributes(attrs);
        MainActivity.immersive = immersive;
        if (activity instanceof MainActivity) ((MainActivity) activity).applyBars();
    }

    @PluginMethod
    public void keys(PluginCall call) {
        keys = Boolean.TRUE.equals(call.getBoolean("on", false));
        call.resolve();
    }

    boolean keysCaptured() {
        return keys;
    }

    void key(String which) {
        JSObject data = new JSObject();
        data.put("key", which);
        notifyListeners("key", data);
    }

    @PluginMethod
    public void flick(PluginCall call) {
        boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
        if (flick == null) {
            call.reject("This phone has no gyroscope.");
            return;
        }
        getActivity().runOnUiThread(() -> {
            if (on) {
                flick.start(direction -> {
                    JSObject data = new JSObject();
                    data.put("direction", direction);
                    notifyListeners("flick", data);
                });
            } else {
                flick.stop();
            }
            call.resolve();
        });
    }

    // Everything back as it was, for a page that's starting afresh.
    private void reset() {
        keys = false;
        if (nearby != null) nearby.reset();
        Activity activity = getActivity();
        if (activity == null) return;
        activity.runOnUiThread(() -> {
            if (flick != null) flick.stop();
            applyScreen(activity, false, false, false);
        });
    }

    @Override
    protected void handleOnDestroy() {
        if (flick != null) flick.stop();
        if (nearby != null) nearby.reset();
        super.handleOnDestroy();
    }

    /* ---- speaking a card ---- */

    private boolean speechAvailable() {
        return new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).resolveActivity(getContext().getPackageManager()) != null;
    }

    @PluginMethod
    public void listen(PluginCall call) {
        String prompt = call.getString("prompt", "Say what the card should read");
        if (prompt == null || prompt.length() > 120) prompt = "Say what the card should read";
        // In the phone's own language, whatever it is.
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
                .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        try {
            startActivityForResult(call, intent, "afterListen");
        } catch (ActivityNotFoundException e) {
            call.reject("No speech recognition on this phone", "unavailable");
        }
    }

    @ActivityCallback
    private void afterListen(PluginCall call, ActivityResult result) {
        if (call == null) return;
        Intent data = result.getData();
        ArrayList<String> heard = data == null ? null : data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);
        if (result.getResultCode() != Activity.RESULT_OK || heard == null || heard.isEmpty() || heard.get(0) == null) {
            call.reject("Cancelled", "cancelled");
            return;
        }
        JSObject out = new JSObject();
        out.put("text", heard.get(0));
        call.resolve(out);
    }

    /* ---- updates and notifications ---- */

    @PluginMethod
    public void update(PluginCall call) {
        UpdateActivity.start(getActivity(), Boolean.TRUE.equals(call.getBoolean("check", false)), call.getString("version"));
        call.resolve();
    }

    @PluginMethod
    public void topics(PluginCall call) {
        SharedPreferences prefs = prefs();
        JSObject out = new JSObject();
        out.put("releases", prefs.getBoolean("topic.releases", false));
        out.put("news", prefs.getBoolean("topic.news", false));
        call.resolve(out);
    }

    @PluginMethod
    public void setTopic(PluginCall call) {
        String topic = call.getString("topic", "");
        boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
        if (!"releases".equals(topic) && !"news".equals(topic)) {
            call.reject("Unknown topic");
            return;
        }
        if (!firebaseReady()) {
            call.reject("This copy of the app can't get notifications yet.");
            return;
        }
        FirebaseMessaging messaging = FirebaseMessaging.getInstance();
        messaging.setAutoInitEnabled(true);
        String name = TOPIC_PREFIX + topic;
        (on ? messaging.subscribeToTopic(name) : messaging.unsubscribeFromTopic(name)).addOnCompleteListener(task -> {
            if (!task.isSuccessful()) {
                call.reject("Couldn't reach Firebase. Check you're online, then try again.");
                return;
            }
            prefs().edit().putBoolean("topic." + topic, on).apply();
            JSObject out = new JSObject();
            out.put("topic", topic);
            out.put("on", on);
            call.resolve(out);
        });
    }

    @PluginMethod
    public void openSettings(PluginCall call) {
        String pkg = getContext().getPackageName();
        String what = call.getString("what");
        Intent intent;
        if ("notifications".equals(what) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, pkg);
        } else if ("bluetooth".equals(what)) {
            intent = new Intent(Settings.ACTION_BLUETOOTH_SETTINGS);
        } else {
            intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null));
        }
        try {
            getActivity().startActivity(intent);
        } catch (ActivityNotFoundException e) {
            getActivity().startActivity(new Intent(Settings.ACTION_SETTINGS));
        }
        call.resolve();
    }

    /* ---- sharing with no wifi (NearbyShare) ---- */

    @PluginMethod
    public void nearbyHost(PluginCall call) {
        if (!nearbyReady(call, "nearbyHostPermission")) return;
        nearbyHostAllowed(call);
    }

    @PermissionCallback
    private void nearbyHostPermission(PluginCall call) {
        if (!nearbyAllowed()) {
            state(call, "denied", null);
            return;
        }
        nearbyHostAllowed(call);
    }

    private void nearbyHostAllowed(PluginCall call) {
        if (!radiosOn(call)) return;
        nearby.host(call.getString("code"), call.getString("tag"), (state, message) -> state(call, state, message));
    }

    @PluginMethod
    public void nearbyStop(PluginCall call) {
        if (nearby != null) nearby.stopHosting();
        call.resolve();
    }

    @PluginMethod
    public void nearbyJoin(PluginCall call) {
        if (!nearbyReady(call, "nearbyJoinPermission")) return;
        nearbyJoinAllowed(call);
    }

    @PermissionCallback
    private void nearbyJoinPermission(PluginCall call) {
        if (!nearbyAllowed()) {
            state(call, "denied", null);
            return;
        }
        nearbyJoinAllowed(call);
    }

    private void nearbyJoinAllowed(PluginCall call) {
        if (!radiosOn(call)) return;
        nearby.join(call.getString("code"), call.getString("tag"), (state, message) -> state(call, state, message));
    }

    @PluginMethod
    public void nearbyLeave(PluginCall call) {
        if (nearby != null) nearby.leave();
        call.resolve();
    }

    @PluginMethod
    public void nearbySend(PluginCall call) {
        String link = call.getString("link", "");
        String data = call.getString("data");
        if (nearby == null || !LINK.matcher(link).matches() || data == null) {
            call.reject("Not a link");
            return;
        }
        long id = nearby.send(link, data);
        if (id == -1) {
            call.reject("That link isn't open");
            return;
        }
        if (id == -2) {
            call.reject("Too big to send in one go");
            return;
        }
        JSObject out = new JSObject();
        out.put("id", Long.toString(id));
        call.resolve(out);
    }

    @PluginMethod
    public void nearbyClose(PluginCall call) {
        String link = call.getString("link", "");
        if (nearby != null && LINK.matcher(link).matches()) nearby.close(link);
        call.resolve();
    }

    // Whether to go on: Play services there, the code and tag sound, and the permissions
    // granted, asking for them if the page said it may (it does from a button).
    private boolean nearbyReady(PluginCall call, String callback) {
        if (nearby == null) {
            state(call, "unsupported", "This phone has no Google Play services, which sharing without wifi needs.");
            return false;
        }
        if (!CODE.matcher(call.getString("code", "")).matches() || !TAG.matcher(call.getString("tag", "")).matches()) {
            call.reject("Not a share code");
            return false;
        }
        if (nearbyAllowed()) return true;
        if (Boolean.TRUE.equals(call.getBoolean("ask", false))) {
            requestPermissionForAliases(nearbyPermissions(), call, callback);
        } else {
            state(call, "needs-permission", null);
        }
        return false;
    }

    // Bluetooth on, and before Android 12, location switched on, which Android wants for finding
    // Bluetooth devices there.
    private boolean radiosOn(PluginCall call) {
        BluetoothManager bm = (BluetoothManager) getContext().getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter adapter = bm == null ? null : bm.getAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            state(call, "bt-off", "Turn on Bluetooth to share without wifi.");
            return false;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            LocationManager lm = (LocationManager) getContext().getSystemService(Context.LOCATION_SERVICE);
            if (lm == null || !LocationManagerCompat.isLocationEnabled(lm)) {
                state(call, "location-off", "Turn on location in this phone's settings to share without wifi.");
                return false;
            }
        }
        return true;
    }

    // What Nearby Connections needs, by Android version.
    private static String[] nearbyPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return new String[] {"bluetooth", "nearbyWifi"};
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return new String[] {"bluetooth", "location"};
        return new String[] {"location"};
    }

    private boolean nearbyAllowed() {
        for (String alias : nearbyPermissions()) {
            if (getPermissionState(alias) != PermissionState.GRANTED) return false;
        }
        return true;
    }

    // Refusals are answers, not errors, so the page can say what to do.
    private static void state(PluginCall call, String state, String message) {
        JSObject out = new JSObject();
        out.put("state", state);
        if (message != null) out.put("message", message);
        call.resolve(out);
    }

    private SharedPreferences prefs() {
        return getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // Built with google-services.json, which starts Firebase as the app starts. Without it there
    // is no Firebase, and FirebaseMessaging would throw.
    private boolean firebaseReady() {
        return !FirebaseApp.getApps(getContext()).isEmpty();
    }
}
