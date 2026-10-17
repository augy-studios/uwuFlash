/*
 * Sharing phone to phone with no wifi or internet: two or more phones running this app talk
 * directly over Google's Nearby Connections (Bluetooth to find each other, then a direct wifi
 * link between them once they've met). The page's sharing (main-site/js/p2p.js, js/nearby.js)
 * uses it beside its usual PeerJS connection, so a phone with the app joins whichever way
 * reaches first, and with no network at all only this way can.
 *
 * This is only a pipe: messages from the page go out as they are, and what arrives goes back to
 * the page. The page's sharing is the same over it as over PeerJS.
 *
 * Sharing phone: advertises as "uwuflash:<tag>", where the tag is a slow hash of the share code
 * made by the page (js/nearby.js), so phones nearby don't see the code itself. Anyone may
 * connect, but a link is only handed to the page once the other phone has sent the code itself
 * over the connection, which Nearby encrypts: { nearby: "hello", v, code }, answered
 * { nearby: "ok" } or { nearby: "no" }.
 *
 * Other screen: looks for that name, connects, sends the hello, and hands the link to the page
 * once it's answered ok. If the connection fails it looks again until the page gives up.
 *
 * A message is at most 32 KB (Nearby's own limit for one payload); the page splits longer ones.
 * Each sent message is reported back once it has gone or failed, so the page knows how much is
 * still on its way and can hold back rather than pile up a backlog on a slow link.
 *
 * Needs Google Play services on every phone, which nearly every Android phone sold with Google's
 * apps has.
 */
package org.uwuapps.flash;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.nearby.Nearby;
import com.google.android.gms.nearby.connection.AdvertisingOptions;
import com.google.android.gms.nearby.connection.ConnectionInfo;
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback;
import com.google.android.gms.nearby.connection.ConnectionResolution;
import com.google.android.gms.nearby.connection.ConnectionsClient;
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes;
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo;
import com.google.android.gms.nearby.connection.DiscoveryOptions;
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback;
import com.google.android.gms.nearby.connection.Payload;
import com.google.android.gms.nearby.connection.PayloadCallback;
import com.google.android.gms.nearby.connection.PayloadTransferUpdate;
import com.google.android.gms.nearby.connection.Strategy;

import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

final class NearbyShare {
    /** What the page hears, on the main thread. Links are Nearby's endpoint ids. */
    interface Events {
        /** A link that has passed the code check, ready for the page's messages. */
        void open(String link);

        void data(String link, String text);

        /** An open link that has gone. Links that never opened are never mentioned. */
        void closed(String link);

        /** A message sent with send() has gone (ok) or failed. */
        void sent(String link, long id, boolean ok);
    }

    interface Result {
        void done(String state, String message);
    }

    static final int MAX_BYTES = ConnectionsClient.MAX_BYTES_DATA_SIZE;

    private static final String SERVICE_ID = "org.uwuapps.flash.share";
    private static final String NAME_PREFIX = "uwuflash:";
    private static final String SCREEN_NAME = "uwuflash-screen";
    private static final int PROTOCOL = 1;
    // One sharing phone, up to twelve screens for a Big Screen.
    private static final Strategy STRATEGY = Strategy.P2P_STAR;
    // A phone that connects to the sharing phone and doesn't send the code in this time is let go.
    private static final long HELLO_MS = 10_000;
    // Long enough for a refusal to reach the other phone before hanging up on it.
    private static final long HANG_UP_MS = 1_000;

    private static final class Link {
        final boolean asHost;
        volatile boolean open;

        Link(boolean asHost) {
            this.asHost = asHost;
        }
    }

    private final ConnectionsClient client;
    private final Events events;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, Link> links = new ConcurrentHashMap<>();
    private final Map<Long, String> inFlight = new ConcurrentHashMap<>();

    // Sharing: the code a screen has to send.
    private volatile String hostCode;
    // Joining: the code to send, and the name to look for.
    private volatile String joinCode;
    private volatile String joinName;
    private volatile boolean connecting;

    NearbyShare(Context context, Events events) {
        client = Nearby.getConnectionsClient(context.getApplicationContext());
        this.events = events;
    }

    static boolean available(Context context) {
        return GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS;
    }

    /* ---- sharing ---- */

    void host(String code, String tag, Result result) {
        stopHosting();
        hostCode = code;
        AdvertisingOptions options = new AdvertisingOptions.Builder().setStrategy(STRATEGY).build();
        client.startAdvertising(NAME_PREFIX + tag, SERVICE_ID, hostConnections, options)
                .addOnSuccessListener(v -> result.done("ready", null))
                .addOnFailureListener(e -> {
                    if (status(e) == ConnectionsStatusCodes.STATUS_ALREADY_ADVERTISING) result.done("ready", null);
                    else result.done("failed", failure(e));
                });
    }

    void stopHosting() {
        if (hostCode == null) return;
        hostCode = null;
        client.stopAdvertising();
        dropLinks(true);
    }

    private final ConnectionLifecycleCallback hostConnections = new ConnectionLifecycleCallback() {
        @Override
        public void onConnectionInitiated(String endpoint, ConnectionInfo info) {
            if (hostCode == null) {
                client.rejectConnection(endpoint);
                return;
            }
            // Anyone may knock: the code they send decides (payloads).
            links.put(endpoint, new Link(true));
            client.acceptConnection(endpoint, payloads);
        }

        @Override
        public void onConnectionResult(String endpoint, ConnectionResolution result) {
            if (!result.getStatus().isSuccess()) {
                links.remove(endpoint);
                return;
            }
            main.postDelayed(() -> {
                Link link = links.get(endpoint);
                if (link != null && !link.open) hangUp(endpoint);
            }, HELLO_MS);
        }

        @Override
        public void onDisconnected(String endpoint) {
            gone(endpoint);
        }
    };

    /* ---- joining ---- */

    void join(String code, String tag, Result result) {
        leave();
        joinCode = code;
        joinName = NAME_PREFIX + tag;
        connecting = false;
        discover(result);
    }

    private void discover(Result result) {
        DiscoveryOptions options = new DiscoveryOptions.Builder().setStrategy(STRATEGY).build();
        client.startDiscovery(SERVICE_ID, discovery, options)
                .addOnSuccessListener(v -> {
                    if (result != null) result.done("searching", null);
                })
                .addOnFailureListener(e -> {
                    if (status(e) == ConnectionsStatusCodes.STATUS_ALREADY_DISCOVERING) {
                        if (result != null) result.done("searching", null);
                    } else if (result != null) {
                        result.done("failed", failure(e));
                    }
                });
    }

    // Looks again after a connection that came to nothing, while the page still wants one.
    private void discoverAgain() {
        connecting = false;
        if (joinCode != null) discover(null);
    }

    void leave() {
        if (joinCode == null) return;
        joinCode = null;
        joinName = null;
        connecting = false;
        client.stopDiscovery();
        dropLinks(false);
    }

    private final EndpointDiscoveryCallback discovery = new EndpointDiscoveryCallback() {
        @Override
        public void onEndpointFound(String endpoint, DiscoveredEndpointInfo info) {
            String wanted = joinName;
            if (wanted == null || connecting || !wanted.equals(info.getEndpointName())) return;
            connecting = true;
            client.stopDiscovery();
            client.requestConnection(SCREEN_NAME, endpoint, screenConnections)
                    .addOnFailureListener(e -> discoverAgain());
        }

        @Override
        public void onEndpointLost(String endpoint) {
        }
    };

    private final ConnectionLifecycleCallback screenConnections = new ConnectionLifecycleCallback() {
        @Override
        public void onConnectionInitiated(String endpoint, ConnectionInfo info) {
            if (joinCode == null) {
                client.rejectConnection(endpoint);
                return;
            }
            links.put(endpoint, new Link(false));
            client.acceptConnection(endpoint, payloads);
        }

        @Override
        public void onConnectionResult(String endpoint, ConnectionResolution result) {
            String code = joinCode;
            if (!result.getStatus().isSuccess() || code == null) {
                links.remove(endpoint);
                discoverAgain();
                return;
            }
            JSONObject hello = new JSONObject();
            try {
                hello.put("nearby", "hello");
                hello.put("v", PROTOCOL);
                hello.put("code", code);
            } catch (JSONException ignored) {
                // Plain values: can't happen.
            }
            client.sendPayload(endpoint, bytes(hello));
        }

        @Override
        public void onDisconnected(String endpoint) {
            Link link = links.get(endpoint);
            gone(endpoint);
            if (link != null && !link.open) discoverAgain();
        }
    };

    /* ---- both ---- */

    private final PayloadCallback payloads = new PayloadCallback() {
        @Override
        public void onPayloadReceived(String endpoint, Payload payload) {
            Link link = links.get(endpoint);
            byte[] data = payload.getType() == Payload.Type.BYTES ? payload.asBytes() : null;
            if (link == null || data == null) return;
            String text = new String(data, StandardCharsets.UTF_8);
            if (link.open) {
                events.data(endpoint, text);
                return;
            }

            // Before the link is open, only the hello and its answer.
            JSONObject in;
            try {
                in = new JSONObject(text);
            } catch (JSONException e) {
                in = new JSONObject();
            }
            if (link.asHost) {
                String code = hostCode;
                boolean ok = "hello".equals(in.optString("nearby")) && in.optInt("v") == PROTOCOL
                        && code != null && code.equals(in.optString("code"));
                JSONObject answer = new JSONObject();
                try {
                    answer.put("nearby", ok ? "ok" : "no");
                } catch (JSONException ignored) {
                    // Plain values: can't happen.
                }
                client.sendPayload(endpoint, bytes(answer));
                if (!ok) {
                    main.postDelayed(() -> hangUp(endpoint), HANG_UP_MS);
                    return;
                }
                link.open = true;
                events.open(endpoint);
            } else if ("ok".equals(in.optString("nearby"))) {
                link.open = true;
                connecting = false;
                events.open(endpoint);
            } else {
                // A different share, or a phone on another version: look for the right one.
                hangUp(endpoint);
                discoverAgain();
            }
        }

        @Override
        public void onPayloadTransferUpdate(String endpoint, PayloadTransferUpdate update) {
            int status = update.getStatus();
            if (status == PayloadTransferUpdate.Status.IN_PROGRESS) return;
            if (inFlight.remove(update.getPayloadId()) != null) {
                events.sent(endpoint, update.getPayloadId(), status == PayloadTransferUpdate.Status.SUCCESS);
            }
        }
    };

    /**
     * Sends one message on an open link: its payload id, reported to Events.sent once it has
     * gone; -1 for a link that isn't open; -2 for a message over MAX_BYTES.
     */
    long send(String endpoint, String text) {
        Link link = links.get(endpoint);
        if (link == null || !link.open) return -1;
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        if (data.length > MAX_BYTES) return -2;
        Payload payload = Payload.fromBytes(data);
        long id = payload.getId();
        inFlight.put(id, endpoint);
        client.sendPayload(endpoint, payload).addOnFailureListener(e -> {
            if (inFlight.remove(id) != null) events.sent(endpoint, id, false);
        });
        return id;
    }

    /** Hangs up on one link the page is done with. The page already knows, so nothing is said. */
    void close(String endpoint) {
        hangUp(endpoint);
    }

    /** Everything off: a new page has no use for the last one's links. */
    void reset() {
        stopHosting();
        leave();
        client.stopAllEndpoints();
        links.clear();
        inFlight.clear();
    }

    private void hangUp(String endpoint) {
        links.remove(endpoint);
        inFlight.values().removeIf(endpoint::equals);
        client.disconnectFromEndpoint(endpoint);
    }

    private void gone(String endpoint) {
        Link link = links.remove(endpoint);
        inFlight.values().removeIf(endpoint::equals);
        if (link != null && link.open) events.closed(endpoint);
    }

    // The links on one side, hung up on without telling the page: it asked for this.
    private void dropLinks(boolean asHost) {
        for (Map.Entry<String, Link> entry : links.entrySet()) {
            if (entry.getValue().asHost == asHost) hangUp(entry.getKey());
        }
    }

    private static Payload bytes(JSONObject json) {
        return Payload.fromBytes(json.toString().getBytes(StandardCharsets.UTF_8));
    }

    private static int status(Exception e) {
        return e instanceof ApiException ? ((ApiException) e).getStatusCode() : -1;
    }

    static String failure(Exception e) {
        int code = status(e);
        if (code == ConnectionsStatusCodes.STATUS_BLUETOOTH_ERROR) return "Turn Bluetooth off and on again, then try again.";
        if (code == ConnectionsStatusCodes.STATUS_RADIO_ERROR) return "Turn Bluetooth on, then try again.";
        return "Sharing without wifi didn't start. Try again.";
    }
}
