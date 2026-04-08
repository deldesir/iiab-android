/*
 ============================================================================
 Name        : TProxyService.java
 Author      : hev <r@hev.cc>
 Contributors: IIAB Project
 Copyright   : Copyright (c) 2024 xyz
 Copyright (c) 2026 IIAB Project
 Description : TProxy Service with integrated Watchdog
 ============================================================================
 */

package org.iiab.controller;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.app.Notification;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.VpnService;
import android.net.wifi.WifiManager;
import android.content.pm.PackageManager.NameNotFoundException;
import android.content.pm.ServiceInfo;
import android.util.Log;

import androidx.core.app.NotificationCompat;

public class TProxyService extends VpnService {
	private static final String TAG = "IIAB-TProxy";
	private static native void TProxyStartService(String config_path, int fd);
	private static native void TProxyStopService();
	private static native long[] TProxyGetStats();

	public static final String ACTION_CONNECT = "org.iiab.controller.CONNECT";
	public static final String ACTION_DISCONNECT = "org.iiab.controller.DISCONNECT";
	public static final String ACTION_WATCHDOG_SYNC = "org.iiab.controller.WATCHDOG_SYNC";

	private PowerManager.WakeLock wakeLock;
	private WifiManager.WifiLock wifiLock;
	
	private Thread watchdogThread;
	private volatile boolean isWatchdogRunning = false;

	static {
		System.loadLibrary("hev-socks5-tunnel");
	}

	private ParcelFileDescriptor tunFd = null;

	@Override
	public void onCreate() {
		super.onCreate();
	}

	@Override
	public int onStartCommand(Intent intent, int flags, int startId) {
		if (intent != null) {
			String action = intent.getAction();
			if (ACTION_DISCONNECT.equals(action)) {
				stopService();
				return START_NOT_STICKY;
			} else if (ACTION_WATCHDOG_SYNC.equals(action)) {
				syncWatchdogLocks();
				return START_STICKY;
			}
		}
		startService();
		return START_STICKY;
	}

	private void syncWatchdogLocks() {
		Preferences prefs = new Preferences(this);
		boolean watchdogEnabled = prefs.getWatchdogEnable();
		Log.d(TAG, getString(R.string.syncing_watchdog, watchdogEnabled));

		if (watchdogEnabled) {
			acquireLocks();
			startWatchdogLoop();
		} else {
			stopWatchdogLoop();
			releaseLocks();
		}
	}

	private void startWatchdogLoop() {
		if (isWatchdogRunning) return;
		
		isWatchdogRunning = true;
		IIABWatchdog.logSessionStart(this);
		
		watchdogThread = new Thread(() -> {
			Log.i(TAG, getString(R.string.watchdog_thread_started));
			while (isWatchdogRunning) {
				try {
					// Perform only the heartbeat stimulus (Intent-based)
					IIABWatchdog.performHeartbeat(this);
					
					// TROUBLESHOOTING: Uncomment to test Termux responsiveness via ping
					// IIABWatchdog.performDebugPing(this);
					
					// Sleep for 30 seconds
					Thread.sleep(30000);
				} catch (InterruptedException e) {
					Log.i(TAG, getString(R.string.watchdog_thread_interrupted));
					break;
				} catch (Exception e) {
					Log.e(TAG, getString(R.string.watchdog_thread_error), e);
				}
			}
			Log.i(TAG, getString(R.string.watchdog_thread_ended));
		});
		watchdogThread.setName("IIAB-Watchdog-Thread");
		watchdogThread.start();
	}

	private void stopWatchdogLoop() {
		isWatchdogRunning = false;
		if (watchdogThread != null) {
			watchdogThread.interrupt();
			watchdogThread = null;
		}
		IIABWatchdog.logSessionStop(this);
	}

	private void acquireLocks() {
		try {
			if (wakeLock == null) {
				PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
				wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "IIAB:TProxyWakeLock");
				wakeLock.acquire();
				Log.i(TAG, getString(R.string.cpu_wakelock_acquired));
			}
			if (wifiLock == null) {
				WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
				wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "IIAB:TProxyWifiLock");
				wifiLock.acquire();
				Log.i(TAG, getString(R.string.wifi_lock_acquired));
			}
		} catch (Exception e) {
			Log.e(TAG, getString(R.string.error_acquiring_locks), e);
		}
	}

	private void releaseLocks() {
		if (wakeLock != null && wakeLock.isHeld()) {
			wakeLock.release();
			wakeLock = null;
			Log.i(TAG, getString(R.string.cpu_wakelock_released));
		}
		if (wifiLock != null && wifiLock.isHeld()) {
			wifiLock.release();
			wifiLock = null;
			Log.i(TAG, getString(R.string.wifi_lock_released));
		}
	}

	@Override
	public void onDestroy() {
		stopWatchdogLoop();
		releaseLocks();
		super.onDestroy();
	}

	@Override
	public void onRevoke() {
		super.onRevoke();
	}

	public void startService() {
		if (tunFd != null) {
			syncWatchdogLocks();
			return;
		}

		Preferences prefs = new Preferences(this);

		/* VPN */
		String session = new String();
		VpnService.Builder builder = new VpnService.Builder();
		builder.setBlocking(false);
		builder.setMtu(prefs.getTunnelMtu());
		if (prefs.getIpv4()) {
			String addr = prefs.getTunnelIpv4Address();
			int prefix = prefs.getTunnelIpv4Prefix();
			String dns = prefs.getDnsIpv4();
			builder.addAddress(addr, prefix);
			builder.addRoute("0.0.0.0", 0);
			if (!prefs.getRemoteDns() && !dns.isEmpty())
			  builder.addDnsServer(dns);
			session += "IPv4";
		}
		if (prefs.getIpv6()) {
			String addr = prefs.getTunnelIpv6Address();
			int prefix = prefs.getTunnelIpv6Prefix();
			String dns = prefs.getDnsIpv6();
			builder.addAddress(addr, prefix);
			builder.addRoute("::", 0);
			if (!prefs.getRemoteDns() && !dns.isEmpty())
			  builder.addDnsServer(dns);
			if (!session.isEmpty())
			  session += " + ";
			session += "IPv6";
		}
		if (prefs.getRemoteDns()) {
			builder.addDnsServer(prefs.getMappedDns());
		}
		boolean disallowSelf = true;
		if (prefs.getGlobal()) {
			session += "/Global";
		} else {
			for (String appName : prefs.getApps()) {
				try {
					builder.addAllowedApplication(appName);
					disallowSelf = false;
				} catch (NameNotFoundException e) {
				}
			}
			session += "/per-App";
		}
		if (disallowSelf) {
			String selfName = getApplicationContext().getPackageName();
			try {
				builder.addDisallowedApplication(selfName);
				if (prefs.getMaintenanceMode()) { // Verify if the maintenance mode is enabled
					builder.addDisallowedApplication("com.termux");
					Log.i(TAG, getString(R.string.maintenance_mode_enabled));
				}
			} catch (NameNotFoundException e) {
			}
		}
		builder.setSession(session);
		tunFd = builder.establish();
		if (tunFd == null) {
			stopSelf();
			return;
		}

		/* TProxy */
		File tproxy_file = new File(getCacheDir(), "tproxy.conf");
		try {
			tproxy_file.createNewFile();
			FileOutputStream fos = new FileOutputStream(tproxy_file, false);

			String tproxy_conf = "misc:\n" +
				"  task-stack-size: " + prefs.getTaskStackSize() + "\n" +
				"tunnel:\n" +
				"  mtu: " + prefs.getTunnelMtu() + "\n";

			tproxy_conf += "socks5:\n" +
				"  port: " + prefs.getSocksPort() + "\n" +
				"  address: '" + prefs.getSocksAddress() + "'\n" +
				"  udp: '" + (prefs.getUdpInTcp() ? "tcp" : "udp") + "'\n";

			if (!prefs.getSocksUdpAddress().isEmpty()) {
				tproxy_conf += "  udp-address: '" + prefs.getSocksUdpAddress() + "'\n";
			}

			if (!prefs.getSocksUsername().isEmpty() &&
				!prefs.getSocksPassword().isEmpty()) {
				tproxy_conf += "  username: '" + prefs.getSocksUsername() + "'\n";
				tproxy_conf += "  password: '" + prefs.getSocksPassword() + "'\n";
			}

			if (prefs.getRemoteDns()) {
				tproxy_conf += "mapdns:\n" +
					"  address: " + prefs.getMappedDns() + "\n" +
					"  port: 53\n" +
					"  network: 240.0.0.0\n" +
					"  netmask: 240.0.0.0\n" +
					"  cache-size: 10000\n";
			}

			fos.write(tproxy_conf.getBytes());
			fos.close();
		} catch (IOException e) {
			return;
		}
		TProxyStartService(tproxy_file.getAbsolutePath(), tunFd.getFd());
		prefs.setEnable(true);

		String channelName = getString(R.string.tproxy_channel_name);
		initNotificationChannel(channelName);
		createNotification(channelName);

		// Start loop and locks if enabled
		syncWatchdogLocks();
	}

	public void stopService() {
		if (tunFd == null)
		  return;

		stopWatchdogLoop();
		releaseLocks();
		stopForeground(true);

		/* TProxy */
		TProxyStopService();

		/* VPN */
		try {
			tunFd.close();
		} catch (IOException e) {
		}
		tunFd = null;

		System.exit(0);
	}

	private void createNotification(String channelName) {
		Intent i = new Intent(this, MainActivity.class);
		i.setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
		PendingIntent pi = PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE);
		NotificationCompat.Builder notification = new NotificationCompat.Builder(this, channelName);
		Notification notify = notification
				.setContentTitle(getString(R.string.app_name))
				.setSmallIcon(android.R.drawable.sym_def_app_icon)
				.setContentIntent(pi)
				.build();
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
			startForeground(1, notify);
		} else {
			startForeground(1, notify, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
		}
	}

	// create NotificationChannel
	private void initNotificationChannel(String channelName) {
		NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			CharSequence name = getString(R.string.app_name);
			NotificationChannel channel = new NotificationChannel(channelName, name, NotificationManager.IMPORTANCE_DEFAULT);
			notificationManager.createNotificationChannel(channel);
		}
	}
}
