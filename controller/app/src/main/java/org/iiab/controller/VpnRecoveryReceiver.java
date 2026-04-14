/*
 * ============================================================================
 * Name        : VpnRecoveryReceiver
 * Author      : IIAB Project
 * Copyright   : Copyright (c) 2026 IIAB Project
 * Description : Button Tunnel helper
 * ============================================================================
 */
package org.iiab.controller;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

import androidx.core.app.NotificationCompat;

public class VpnRecoveryReceiver extends BroadcastReceiver {
    private static final String TAG = "IIAB-VpnRecovery";
    public static final String EXTRA_RECOVERY = "recovery_mode";
    private static final String CHANNEL_ID = "recovery_channel";
    private static final int NOTIFICATION_ID = 911;

    @Override
    public void onReceive(Context context, Intent intent) {
        if ("org.iiab.controller.RECOVER_VPN".equals(intent.getAction())) {
            Log.i(TAG, "Boomerang Signal Received! Triggering high-priority recovery...");

            Preferences prefs = new Preferences(context);
            if (prefs.getEnable()) {
                showRecoveryNotification(context);
            }
        }
    }

    private void showRecoveryNotification(Context context) {
        NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, context.getString(R.string.recovery_channel_name),
                    NotificationManager.IMPORTANCE_HIGH
            );
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
            if (manager != null) manager.createNotificationChannel(channel);
        }

        Intent uiIntent = new Intent(context, MainActivity.class);
        uiIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        uiIntent.putExtra(EXTRA_RECOVERY, true);

        PendingIntent pendingIntent = PendingIntent.getActivity(
                context, 0, uiIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_alert)
                .setContentTitle(context.getString(R.string.recovery_notif_title))
                .setContentText(context.getString(R.string.recovery_notif_text))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(true)
                .setOngoing(true)
                .setFullScreenIntent(pendingIntent, true) // High priority request to open
                .setContentIntent(pendingIntent);

        if (manager != null) {
            manager.notify(NOTIFICATION_ID, builder.build());
        }
    }
}
