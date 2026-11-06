/*
 * Firebase Cloud Messaging's pushes, with the app's process up. With the app in the background, a
 * push with a notification is shown by Android itself and never comes here; with it in front, it
 * comes here, and is shown the same way so it isn't lost (Capacitor's presentationOptions did this
 * in 1.0.0).
 */
package org.uwuapps.flash;

import androidx.annotation.NonNull;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public class MessagingService extends FirebaseMessagingService {

    @Override
    public void onMessageReceived(@NonNull RemoteMessage message) {
        RemoteMessage.Notification n = message.getNotification();
        if (n == null) return;
        Notifications.show(this, n.getChannelId(), n.getTag(), n.getTitle(), n.getBody(), message.getData());
    }
}
