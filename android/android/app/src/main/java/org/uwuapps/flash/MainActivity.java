/*
 * The app (1.1.0): its screens are Flutter's (android/lib/), in a FlutterFragment here, with this
 * app's plugins reached from the Dart side over the bridge (bridge/Bridge.java,
 * android/lib/native/native_bridge.dart):
 *
 *   FlashPlugin    what the app can do: the presenter's screen (kept on, full brightness, every
 *                  bar hidden), the volume keys and flicks changing cards, speaking a card, sharing
 *                  with no wifi, updating itself, notifications, the phone's fonts
 *   MigratePlugin  the cards and pictures kept when the app was a WebView (1.0.0)
 *
 * Here: what the app was opened with (one of the site's own links, such as a scanned share code,
 * a uwu://flash/ link, or a tapped notification) handed to the Dart side, the volume keys while
 * presenting, the notification channels, and drawing edge to edge.
 *
 * An AppCompatActivity rather than a FlutterActivity, so the bridge can register for Android's
 * permission prompts and activity results, and the splash screen works as it did.
 */
package org.uwuapps.flash;

import android.content.Intent;
import android.content.res.Configuration;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.splashscreen.SplashScreen;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;
import androidx.fragment.app.FragmentManager;

import org.uwuapps.flash.bridge.Bridge;

import io.flutter.embedding.android.FlutterEngineConfigurator;
import io.flutter.embedding.android.FlutterFragment;
import io.flutter.embedding.android.RenderMode;
import io.flutter.embedding.android.TransparencyMode;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister;

public class MainActivity extends AppCompatActivity implements FlutterEngineConfigurator {
    static final String SITE = "https://flash.uwuapps.org";
    static final String HOST = "flash.uwuapps.org";
    private static final String FLUTTER_TAG = "flutter";

    // Every bar hidden while presenting or showing shared cards full screen (FlashPlugin.screen).
    static volatile boolean immersive;

    private Bridge mBridge;
    private FlutterFragment mFlutter;

    // A volume key held down: it toggles the card's ticker once, and changes no card on release.
    private boolean volumeHeld;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        SplashScreen.installSplashScreen(this);
        super.onCreate(savedInstanceState);
        Notifications.createChannels(this);

        // The Dart side draws under the bars and keeps clear of them itself, and runs up into the
        // camera's cutout rather than leaving a black strip there on phones before Android 15.
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams attrs = getWindow().getAttributes();
            attrs.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            getWindow().setAttributes(attrs);
        }

        mBridge = new Bridge(this);
        mBridge.registerPlugin(FlashPlugin.class);
        mBridge.registerPlugin(MigratePlugin.class);

        FrameLayout root = new FrameLayout(this);
        root.setId(R.id.flutter_container);
        setContentView(root);
        FragmentManager fm = getSupportFragmentManager();
        mFlutter = (FlutterFragment) fm.findFragmentByTag(FLUTTER_TAG);
        if (mFlutter == null) {
            // Back is the Dart side's: the presenter, what's open, then to the background.
            mFlutter = FlutterFragment.withNewEngine()
                    .renderMode(RenderMode.surface)
                    .transparencyMode(TransparencyMode.opaque)
                    .shouldAutomaticallyHandleOnBackPressed(true)
                    .build();
            fm.beginTransaction().add(R.id.flutter_container, mFlutter, FLUTTER_TAG).commit();
        }
        // What the app was opened with, the first time: its screen, once the Dart side listens.
        if (savedInstanceState == null) route(getIntent());
    }

    // The Flutter engine's made: its plugins (shared_preferences, WebRTC, picking a file), then
    // the bridge to it. A FlutterFragment's engine doesn't register its plugins itself: it leaves
    // that to the activity. Without them the Dart side's first await fails before runApp, and the
    // app never opens.
    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        GeneratedPluginRegister.registerGeneratedPlugins(engine);
        mBridge.connect(engine.getDartExecutor().getBinaryMessenger());
    }

    @Override
    public void cleanUpFlutterEngine(@NonNull FlutterEngine engine) {
        mBridge.disconnect();
    }

    @Override
    protected void onDestroy() {
        mBridge.onDestroy();
        super.onDestroy();
    }

    @Override
    protected void onStart() {
        super.onStart();
        mBridge.onStart();
    }

    @Override
    protected void onStop() {
        mBridge.onStop();
        super.onStop();
    }

    @Override
    public void onResume() {
        super.onResume();
        mBridge.onResume();
    }

    @Override
    public void onPause() {
        mBridge.onPause();
        super.onPause();
    }

    @Override
    public void onPostResume() {
        super.onPostResume();
        if (mFlutter != null) mFlutter.onPostResume();
    }

    // The Flutter plugins' own screens (picking a file) come back to the activity: handed on to
    // them, as FlutterFragmentActivity does.
    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (mFlutter != null) mFlutter.onRequestPermissionsResult(requestCode, permissions, grantResults);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (mFlutter != null) mFlutter.onActivityResult(requestCode, resultCode, data);
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if (mFlutter != null) mFlutter.onTrimMemory(level);
    }

    @Override
    protected void onUserLeaveHint() {
        super.onUserLeaveHint();
        if (mFlutter != null) mFlutter.onUserLeaveHint();
    }

    // The volume keys change cards while presenting (FlashPlugin.keys): down for the next card,
    // up for the one before, as in a reading app, so the phone can be held up facing the room
    // and worked without looking. Held, either toggles the card's ticker. The rest of the time
    // they set the volume as usual.
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

    // Again whenever the window comes back, as the notification shade or another app can leave
    // the bars showing.
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) applyBars();
    }

    void applyBars() {
        WindowInsetsControllerCompat bars = WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        bars.setSystemBarsBehavior(WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        if (immersive) bars.hide(WindowInsetsCompat.Type.systemBars());
        else bars.show(WindowInsetsCompat.Type.systemBars());
    }

    @Override
    public void onConfigurationChanged(@NonNull Configuration config) {
        super.onConfigurationChanged(config);
        applyBars();
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (mFlutter != null) mFlutter.onNewIntent(intent);
        route(intent);
    }

    // What an intent asks for, the one the app was opened with or a later one.
    private void route(Intent intent) {
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
        if (url != null) FlashPlugin.open(url);
    }

    // The site's page an intent asks for, or null for nothing in particular.
    static String pageFor(Intent intent) {
        if (intent == null) return null;
        Uri data = intent.getData();
        if (data == null) return null;
        // Not again when reopened from the recent apps, which hands back the same intent.
        if ((intent.getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null;
        // The site's own links, such as a share code's: https://flash.uwuapps.org/?join=CODE
        if ("https".equals(data.getScheme()) && HOST.equalsIgnoreCase(data.getHost())) {
            return data.toString();
        }
        // uwu://flash/?join=CODE to the same page on the site. uwu:// is shared by UwU Apps'
        // apps, each answering its own host. Only a join code carries over, which the Dart side
        // checks again.
        if ("uwu".equals(data.getScheme()) && "flash".equalsIgnoreCase(data.getHost())) {
            String join = data.getQueryParameter("join");
            if (join != null && join.matches("[A-Za-z0-9 -]{1,12}")) return SITE + "/?join=" + Uri.encode(join);
            return SITE + "/";
        }
        return null;
    }
}
