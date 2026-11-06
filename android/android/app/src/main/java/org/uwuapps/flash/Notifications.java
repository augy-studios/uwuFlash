/*
 * The app's notification channels, each its own switch in Android's settings for the app:
 *
 *   releases  a new version of the app is out (main-site/api/push/release.js)
 *   news      news from uwuFlash, sent from the Firebase console (android/FIREBASE-SETUP.md)
 *
 * Both come from FCM topics you join under Notifications in the Edge Tray (FlashPlugin.setTopic),
 * and the pushes name these channels (main-site/api/_lib/fcm.js). Android only takes a channel's
 * sound and importance from when it's made, so changing one means a new id.
 */
package org.uwuapps.flash;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

import androidx.core.content.ContextCompat;

import java.util.Map;

final class Notifications {
    static final String RELEASES = "releases";
    static final String NEWS = "news";

    private Notifications() {}

    static void createChannels(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = context.getSystemService(NotificationManager.class);

        NotificationChannel releases = new NotificationChannel(RELEASES, "New versions",
                NotificationManager.IMPORTANCE_DEFAULT);
        releases.setDescription("When a new version of the app is out");

        NotificationChannel news = new NotificationChannel(NEWS, "News from uwuFlash",
                NotificationManager.IMPORTANCE_DEFAULT);
        news.setDescription("Now and then: new features, and other news");

        manager.createNotificationChannel(releases);
        manager.createNotificationChannel(news);
    }

    /** A push that came with the app in front. Tapped, it opens the app with the push's data, as
     * one Android showed by itself does (MainActivity.route). */
    static void show(Context context, String channel, String tag, String title, String body, Map<String, String> data) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        if (manager == null || !manager.areNotificationsEnabled()) return;

        Intent open = new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        if (data != null) for (Map.Entry<String, String> e : data.entrySet()) open.putExtra(e.getKey(), e.getValue());
        int code = tag == null ? 0 : tag.hashCode();
        PendingIntent tap = PendingIntent.getActivity(context, code, open,
                PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0));

        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(context, RELEASES.equals(channel) ? RELEASES : NEWS)
                : new Notification.Builder(context);
        builder.setSmallIcon(R.drawable.ic_notification_icon)
                .setColor(ContextCompat.getColor(context, R.color.notification))
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(tap)
                .setAutoCancel(true);
        manager.notify(tag, 1, builder.build());
    }
}
