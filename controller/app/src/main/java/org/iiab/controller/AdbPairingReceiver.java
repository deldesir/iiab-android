package org.iiab.controller;

import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.Toast;

import androidx.core.app.RemoteInput;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class AdbPairingReceiver extends BroadcastReceiver {

    public static final String KEY_PIN_REPLY = "key_pin_reply";
    public static final int NOTIFICATION_ID = 9401;
    private static final String TAG = "AdbPairingNative";

    // Use an Executor to avoid blocking the main thread (UI) during cryptography
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    @Override
    public void onReceive(Context context, Intent intent) {
        Bundle remoteInput = RemoteInput.getResultsFromIntent(intent);
        if (remoteInput != null) {
            CharSequence pinSequence = remoteInput.getCharSequence(KEY_PIN_REPLY);
            int connectPort = intent.getIntExtra("connectPort", -1);
            int pairingPort = intent.getIntExtra("pairingPort", -1);

            if (pinSequence != null && connectPort != -1 && pairingPort != -1) {
                String pin = pinSequence.toString().trim();

                if (pin.length() == 6) {
                    Toast.makeText(context, R.string.adb_toast_pairing, Toast.LENGTH_SHORT).show();

                    // Remove the notification immediately
                    NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
                    if (nm != null) {
                        nm.cancel(NOTIFICATION_ID);
                    }

                    // --- NATIVE ADB MAGIC ---
                    // Pass the context (to save keys) and ports to the background thread
                    performNativePairing(context.getApplicationContext(), pairingPort, connectPort, pin);

                } else {
                    Toast.makeText(context, R.string.adb_toast_pin_invalid, Toast.LENGTH_LONG).show();
                }
            }
        }
    }

    private void performNativePairing(Context context, int pairingPort, int connectPort, String pin) {
        executor.execute(() -> {
            try {
                IIABAdbManager adbManager = IIABAdbManager.getInstance(context);
                boolean isPaired = adbManager.pair("127.0.0.1", pairingPort, pin);

                if (isPaired) {
                    Log.i(TAG, "Native Pairing SUCCESSFUL!");
                    adbManager.connect("127.0.0.1", connectPort);
                    Log.i(TAG, "God Mode (ADB) connected and persistent!");

                    // Notify the UI
                    Intent uiUpdateIntent = new Intent("org.iiab.controller.ADB_PAIRING_SENT");
                    uiUpdateIntent.setPackage(context.getPackageName());
                    context.sendBroadcast(uiUpdateIntent);

                    // Start the CPU Stream from the Singleton
                    adbManager.startCpuMonitor(context);
                    adbManager.checkSystemRestrictions(context);

                } else {
                    Log.e(TAG, "Native pairing failed (Incorrect PIN).");
                    showToastOnMainThread(context, context.getString(R.string.adb_toast_pairing_failed));
                }
            } catch (Exception e) {
                Log.e(TAG, "Exception in native ADB pairing", e);
                showToastOnMainThread(context, "Error: " + e.getMessage());
            }
        });
    }

    private void showToastOnMainThread(Context context, String message) {
        new Handler(Looper.getMainLooper()).post(() ->
                Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        );
    }
}