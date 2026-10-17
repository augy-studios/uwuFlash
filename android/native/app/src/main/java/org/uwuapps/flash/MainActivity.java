/*
 * The app: the site at flash.uwuapps.org in Capacitor's WebView (capacitor.config.json's
 * server.url), so the site's own updates reach it at once, with this app's plugin injected into
 * its pages for what a web page can't do (main-site/js/app-bridge.js):
 *
 *   FlashPlugin        what the app can do: the presenter's screen (kept on, full brightness,
 *                      every bar hidden), the volume keys and flicks changing cards, speaking a
 *                      card, sharing with no wifi, updating itself, notifications
 *   PushNotifications  Capacitor's, for Android's notification permission and the pushes
 *
 * Here: what the app was opened with (one of the site's own links, such as a scanned share code,
 * a uwu://flash/ link, or a tapped notification) opened in the page, the back button going back
 * through the page's history (or out of the presenter), the volume keys while presenting, the
 * notification channels, and no status bar.
 */
package org.uwuapps.flash;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.webkit.WebView;

import androidx.activity.OnBackPressedCallback;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    static final String SITE = "https://flash.uwuapps.org";
    static final String HOST = "flash.uwuapps.org";

    // Every bar hidden, the navigation bar too, while the page is presenting or showing shared
    // cards full screen (FlashPlugin.immersive). Otherwise only the status bar is.
    static volatile boolean immersive;

    // A volume key held down: it toggles the card's ticker once, and changes no card on release.
    private boolean volumeHeld;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        registerPlugin(FlashPlugin.class);
        Notifications.createChannels(this);
        super.onCreate(savedInstanceState);

        // The page runs up into the camera's cutout, where the status bar was, rather than
        // leaving a black strip there on phones older than Android 15.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams attrs = getWindow().getAttributes();
            attrs.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(attrs);
        }

        // Back leaves the presenter while it's up, as Escape does in a browser. Otherwise it goes
        // back through the page's history, and off the first page the app goes to the background
        // rather than closing, so the deck and any sharing keep their place.
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                FlashPlugin plugin = FlashPlugin.current();
                if (plugin != null && plugin.keysCaptured()) {
                    plugin.key("back");
                    return;
                }
                WebView web = bridge == null ? null : bridge.getWebView();
                if (web != null && web.canGoBack()) web.goBack();
                else moveTaskToBack(true);
            }
        });
    }

    // The volume keys change cards while presenting (FlashPlugin.keys): down for the next card,
    // up for the one before, as in a reading app, so the phone can be held up facing the room
    // and worked without looking. Held, either toggles the card's ticker. The rest of the time
    // they set the volume as usual. The WebView never sees these keys, so this is the only way.
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        boolean volume = code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_VOLUME_UP;
        FlashPlugin plugin = FlashPlugin.current();
        if (!volume || plugin == null || !plugin.keysCaptured()) return super.dispatchKeyEvent(event);

        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (event.getRepeatCount() == 0) {
                volumeHeld = false;
            } else if (!volumeHeld) {
                // Android repeats a held key after about half a second.
                volumeHeld = true;
                plugin.key("hold");
            }
        } else if (event.getAction() == KeyEvent.ACTION_UP && !volumeHeld && !event.isCanceled()) {
            plugin.key(code == KeyEvent.KEYCODE_VOLUME_DOWN ? "next" : "previous");
        }
        return true;
    }

    // No status bar: the page has the whole screen, and a swipe down from the top shows the bar
    // for a moment. Done here rather than in onCreate because Capacitor's SystemBars shows every
    // bar as it starts, and again whenever the window comes back, as the bar can be left showing
    // by the notification shade or another app. The page leaves no room for the bar
    // (capacitor.config.json's user agent, uwuFlashApp/1, tells it so: js/app-bridge.js).
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) applyBars();
    }

    void applyBars() {
        WindowInsetsControllerCompat bars = WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        bars.setSystemBarsBehavior(WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        if (immersive) {
            bars.hide(WindowInsetsCompat.Type.systemBars());
        } else {
            bars.show(WindowInsetsCompat.Type.navigationBars());
            bars.hide(WindowInsetsCompat.Type.statusBars());
        }
    }

    // BridgeActivity calls this with the intent the app was opened with too, once the page has
    // started loading the site's home page.
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);

        // "Version 1.1.0 of uwuFlash is out", tapped (main-site/api/push/release.js): straight to
        // the update window, which asks before downloading it. Taken off the intent so it isn't
        // asked again if Android recreates the activity with it.
        String type = intent.getStringExtra("type");
        if ("release".equals(type)) {
            UpdateActivity.start(this, true, intent.getStringExtra("version"));
            intent.removeExtra("type");
            return;
        }

        String url = pageFor(intent);
        if (url != null && bridge != null) bridge.getWebView().loadUrl(url);
    }

    // The site's page an intent asks for, or null for the home page as it is.
    static String pageFor(Intent intent) {
        if (intent == null) return null;
        Uri data = intent.getData();
        if (data == null) return null;
        // The site's own links, such as a share code's: https://flash.uwuapps.org/?join=CODE
        if ("https".equals(data.getScheme()) && HOST.equalsIgnoreCase(data.getHost())) {
            return data.toString();
        }
        // uwu://flash/?join=CODE to the same page on the site. uwu:// is shared by UwU Apps'
        // apps, each answering its own host. The site is one page, so only its query carries
        // over, and only a join code, which viewer.js checks again.
        if ("uwu".equals(data.getScheme()) && "flash".equalsIgnoreCase(data.getHost())) {
            String join = data.getQueryParameter("join");
            if (join != null && join.matches("[A-Za-z0-9 -]{1,12}")) return SITE + "/?join=" + Uri.encode(join);
            return SITE + "/";
        }
        return null;
    }
}
