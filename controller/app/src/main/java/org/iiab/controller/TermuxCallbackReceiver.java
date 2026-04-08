/*
 * ============================================================================
 * Name        : TermuxCallbackReceiver.java
 * Author      : IIAB Project
 * Copyright   : Copyright (c) 2026 IIAB Project
 * Description : Termux callback helper
 * ============================================================================
 */
package org.iiab.controller;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;

public class TermuxCallbackReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (IIABWatchdog.ACTION_TERMUX_OUTPUT.equals(intent.getAction())) {
            Bundle resultExtras = intent.getExtras();
            if (resultExtras != null) {
                int exitCode = resultExtras.getInt("exitCode", -1);
                String stdout = resultExtras.getString("stdout", "");
                String stderr = resultExtras.getString("stderr", "");

                String logMsg;
                if (exitCode == 0) {
                    logMsg = "[Termux] Stimulus OK (exit 0)";
                } else {
                    logMsg = "[Termux] Pulse Error (exit " + exitCode + ")";
                    if (!stderr.isEmpty()) {
                        logMsg += ": " + stderr;
                    }
                }
                
                // Write to BlackBox log
                IIABWatchdog.writeToBlackBox(context, logMsg);
            }
        }
    }
}
