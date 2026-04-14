/*
 * ============================================================================
 * Name        : WatchdogService.java
 * Author      : IIAB Project
 * Copyright   : Copyright (c) 2026 IIAB Project
 * Description : Watchdog service helper
 * ============================================================================
 */
package org.iiab.controller;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;

import androidx.core.app.NotificationCompat;

public class WatchdogService extends Service {
    private static final String CHANNEL_ID = "watchdog_channel";
    private static final int NOTIFICATION_ID = 2;

    public static final String ACTION_START = "org.iiab.controller.WATCHDOG_START";
    public static final String ACTION_STOP = "org.iiab.controller.WATCHDOG_STOP";
    public static final String ACTION_HEARTBEAT = "org.iiab.controller.HEARTBEAT";
    public static final String ACTION_STATE_STARTED = "org.iiab.controller.WATCHDOG_STARTED";
    public static final String ACTION_STATE_STOPPED = "org.iiab.controller.WATCHDOG_STOPPED";
    private static final int HEARTBEAT_INTERVAL_MS = 20 * 1000;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            String action = intent.getAction();
            if (ACTION_START.equals(action)) {
                startWatchdog();
            } else if (ACTION_HEARTBEAT.equals(action)) {
                IIABWatchdog.performHeartbeat(this);
                scheduleHeartbeat();
            }
        }
        return START_STICKY;
    }

    private void startWatchdog() {
        Notification notification = createNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }

        IIABWatchdog.logSessionStart(this);
        scheduleHeartbeat();

        Intent startIntent = new Intent(ACTION_STATE_STARTED);
        startIntent.setPackage(getPackageName());
        sendBroadcast(startIntent);
    }

    @Override
    public void onDestroy() {
        // We immediately notify the UI that we are shutting down.
        Intent stopIntent = new Intent(ACTION_STATE_STOPPED);
        stopIntent.setPackage(getPackageName());
        sendBroadcast(stopIntent);

        // We clean up the trash
        cancelHeartbeat();
        IIABWatchdog.logSessionStop(this);
        stopForeground(true);

        super.onDestroy();
    }

    private PendingIntent getHeartbeatPendingIntent() {
        Intent intent = new Intent(this, WatchdogService.class);
        intent.setAction(ACTION_HEARTBEAT);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return PendingIntent.getService(this, 0, intent, flags);
    }

    @android.annotation.SuppressLint("ScheduleExactAlarm")
    private void scheduleHeartbeat() {
        AlarmManager alarmManager = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
        PendingIntent pendingIntent = getHeartbeatPendingIntent();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // This wakes up the device even in Doze Mode
            alarmManager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + HEARTBEAT_INTERVAL_MS,
                    pendingIntent);
        } else {
            alarmManager.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + HEARTBEAT_INTERVAL_MS,
                    pendingIntent);
        }
    }

    private void cancelHeartbeat() {
        AlarmManager alarmManager = (AlarmManager) getSystemService(Context.ALARM_SERVICE);
        PendingIntent pendingIntent = getHeartbeatPendingIntent();
        if (alarmManager != null) {
            alarmManager.cancel(pendingIntent);
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, getString(R.string.watchdog_channel_name),
                    NotificationManager.IMPORTANCE_HIGH
            );
            channel.setDescription(getString(R.string.watchdog_channel_desc));
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification createNotification() {
        Intent notificationIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent,
                PendingIntent.FLAG_IMMUTABLE);

        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(getString(R.string.watchdog_notif_title))
                .setContentText(getString(R.string.watchdog_notif_text))
                .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
                .setContentIntent(pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setOngoing(true)
                .build();
    }
}
