/*
 * The app's data from before it was a Flutter app (1.0.0 was the site in a WebView): the deck,
 * theme and settings the site kept in the WebView's localStorage for https://flash.uwuapps.org,
 * and the pictures it kept in that origin's IndexedDB. Read once, on the first launch after
 * updating (android/lib/data/migrate.dart), by a WebView that's never shown: a blank page given
 * the site's address as its own, so it sees the site's storage, with nothing fetched. It's the
 * only WebView left in the app, and the WebView's copy is left as it was.
 *
 *   read()   { found, items: { key: value }, images: count }: every key the site kept, as strings,
 *            and the pictures written to files/images/<id>, as lib/data/images_io.dart keeps them
 */
package org.uwuapps.flash;

import android.annotation.SuppressLint;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import org.json.JSONException;
import org.json.JSONObject;
import org.uwuapps.flash.bridge.AppPlugin;
import org.uwuapps.flash.bridge.JSObject;
import org.uwuapps.flash.bridge.Plugin;
import org.uwuapps.flash.bridge.PluginCall;
import org.uwuapps.flash.bridge.PluginMethod;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Iterator;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Pattern;

@AppPlugin(name = "Migrate")
public class MigratePlugin extends Plugin {
    private static final String TAG = "uwuFlashMigrate";
    // A picture's id as the site makes them (js/app.js, newImageId).
    private static final Pattern IMAGE_ID = Pattern.compile("[A-Za-z0-9-]{1,64}");
    // Long enough for a phone with many large pictures; after this, what's been read is kept.
    private static final long TIMEOUT_MS = 60_000;
    // Each picture goes across to Java in pieces, as one long string can run the WebView out of
    // memory. A multiple of 3 bytes, so each piece is base64 on its own.
    private static final String DUMP = """
            (function(){
              var out = {};
              try { for (var i = 0; i < localStorage.length; i++) { var k = localStorage.key(i); out[k] = localStorage.getItem(k); } } catch (e) {}
              uwuFlashMigrate.items(JSON.stringify(out));
              function finish() { uwuFlashMigrate.finished(); }
              function read(blob) {
                return new Promise(function (resolve, reject) {
                  var r = new FileReader();
                  r.onload = function () { resolve(r.result); };
                  r.onerror = function () { reject(r.error); };
                  r.readAsDataURL(blob);
                });
              }
              var request;
              try {
                if (!window.indexedDB) { uwuFlashMigrate.note('no indexedDB'); return finish(); }
                request = indexedDB.open('uwuflash-images', 1);
              } catch (e) { uwuFlashMigrate.note('open threw ' + e); return finish(); }
              request.onupgradeneeded = function () {
                if (!request.result.objectStoreNames.contains('images')) request.result.createObjectStore('images');
              };
              request.onerror = function () { uwuFlashMigrate.note('open failed ' + request.error); finish(); };
              request.onsuccess = function () {
                var db = request.result;
                var keys = db.transaction('images', 'readonly').objectStore('images').getAllKeys();
                keys.onerror = function () { uwuFlashMigrate.note('keys failed ' + keys.error); finish(); };
                keys.onsuccess = async function () {
                  uwuFlashMigrate.note('pictures: ' + keys.result.length);
                  for (var id of keys.result) {
                    try {
                      var blob = await new Promise(function (resolve, reject) {
                        var one = db.transaction('images', 'readonly').objectStore('images').get(id);
                        one.onsuccess = function () { resolve(one.result); };
                        one.onerror = function () { reject(one.error); };
                      });
                      if (!blob) continue;
                      var url = String(await read(blob));
                      var data = url.slice(url.indexOf(',') + 1);
                      uwuFlashMigrate.begin(String(id));
                      for (var at = 0; at < data.length; at += 1048576) uwuFlashMigrate.piece(String(id), data.slice(at, at + 1048576));
                      uwuFlashMigrate.end(String(id));
                    } catch (e) { uwuFlashMigrate.note('a picture failed: ' + e); }
                  }
                  finish();
                };
              };
            })();
            """;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @PluginMethod
    public void read(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            WebView web;
            try {
                web = new WebView(getActivity());
            } catch (RuntimeException e) {
                // No WebView on this phone at all (it's being updated, say): nothing to read.
                answer(call, new JSObject(), 0);
                return;
            }
            Reader reader = new Reader(call, web);
            web.getSettings().setJavaScriptEnabled(true);
            web.getSettings().setDomStorageEnabled(true);
            // This page only ever holds the two lines below, and it's never shown.
            web.addJavascriptInterface(reader, "uwuFlashMigrate");
            web.setWebViewClient(new WebViewClient() {
                private boolean started;

                @Override
                public void onPageFinished(WebView view, String url) {
                    if (started) return;
                    started = true;
                    view.evaluateJavascript(DUMP, null);
                }
            });
            web.loadDataWithBaseURL(MainActivity.SITE + "/", "<!doctype html><title></title>", "text/html", "utf-8", null);
            new Handler(Looper.getMainLooper()).postDelayed(reader::finished, TIMEOUT_MS);
        });
    }

    private static void answer(PluginCall call, JSObject items, int images) {
        JSObject out = new JSObject();
        out.put("found", items.length() > 0 || images > 0);
        out.put("items", items);
        out.put("images", images);
        call.resolve(out);
    }

    // What the hidden page calls, on a thread of the WebView's own.
    private final class Reader {
        private final PluginCall call;
        private final WebView web;
        private final AtomicBoolean done = new AtomicBoolean();
        private final JSObject items = new JSObject();
        private final File dir = new File(getContext().getFilesDir(), "images");
        private FileOutputStream open;
        private File writing;
        private volatile int images;

        Reader(PluginCall call, WebView web) {
            this.call = call;
            this.web = web;
        }

        // Why a picture didn't come, in the log: there's nobody to tell.
        @JavascriptInterface
        public void note(String text) {
            Log.i(TAG, text);
        }

        @JavascriptInterface
        public void items(String json) {
            try {
                JSONObject all = new JSONObject(json);
                for (Iterator<String> keys = all.keys(); keys.hasNext(); ) {
                    String k = keys.next();
                    items.put(k, all.optString(k));
                }
            } catch (JSONException e) {
                Log.w(TAG, "The site's settings didn't read", e);
            }
        }

        // To a temporary name first, so a picture cut short never passes for the whole of it.
        @JavascriptInterface
        public void begin(String id) {
            abandon();
            if (!IMAGE_ID.matcher(id).matches()) return;
            try {
                if (!dir.isDirectory() && !dir.mkdirs()) return;
                writing = new File(dir, id + ".part");
                open = new FileOutputStream(writing);
            } catch (IOException e) {
                Log.w(TAG, "No room for a picture", e);
                abandon();
            }
        }

        @JavascriptInterface
        public void piece(String id, String base64) {
            if (open == null) return;
            try {
                open.write(Base64.decode(base64, Base64.DEFAULT));
            } catch (IOException | IllegalArgumentException e) {
                Log.w(TAG, "A picture didn't write", e);
                abandon();
            }
        }

        @JavascriptInterface
        public void end(String id) {
            if (open == null) return;
            try {
                open.close();
                open = null;
                File whole = new File(dir, id);
                if (writing.renameTo(whole)) images++;
            } catch (IOException e) {
                Log.w(TAG, "A picture didn't finish", e);
                abandon();
            }
        }

        private void abandon() {
            try {
                if (open != null) open.close();
            } catch (IOException ignored) {
                // Going anyway.
            }
            open = null;
            if (writing != null) writing.delete();
            writing = null;
        }

        @JavascriptInterface
        public void finished() {
            if (!done.compareAndSet(false, true)) return;
            abandon();
            Log.i(TAG, "Brought " + items.length() + " settings and " + images + " pictures");
            answer(call, items, images);
            getActivity().runOnUiThread(web::destroy);
        }
    }
}
