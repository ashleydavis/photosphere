package dev.ziggy.shell;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

// A foreground service that does nothing but exist while the core has tasks the app must be kept running for. A process with a
// running foreground service is not stopped when the app leaves the foreground, so those tasks go on running. The shell starts it
// when the core asks to keep the app running, which is while the app is in the foreground, as Android requires, and stops it
// when the core says the last such task has ended. What its notification says is the app's to supply (see
// ZiggyShell.setKeepAliveNotification); an app that supplies nothing gets generic wording.
public final class ZiggyKeepAliveService extends Service {
    // The Intent extra holding the name of the notification channel, as the system settings show it.
    static final String EXTRA_CHANNEL_NAME = "dev.ziggy.shell.keepAlive.channelName";

    // The Intent extra holding the description of the notification channel.
    static final String EXTRA_CHANNEL_DESCRIPTION = "dev.ziggy.shell.keepAlive.channelDescription";

    // The Intent extra holding the notification's title.
    static final String EXTRA_TITLE = "dev.ziggy.shell.keepAlive.title";

    // The Intent extra holding the notification's text.
    static final String EXTRA_TEXT = "dev.ziggy.shell.keepAlive.text";

    // The Intent extra that asks a running service to end. It is sent as a start request, not with stopService, because every
    // startForegroundService must be answered by startForeground, and a stop that arrives before the service has answered would crash the
    // app (ForegroundServiceDidNotStartInTimeException).
    static final String EXTRA_STOP = "dev.ziggy.shell.keepAlive.stop";

    private static final String CHANNEL_ID = "ziggy-keep-alive";
    private static final int NOTIFICATION_ID = 0x5A01;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        CharSequence appName = getApplicationInfo().loadLabel(getPackageManager());
        String channelName = extra(intent, EXTRA_CHANNEL_NAME, "Background work");
        String channelDescription = extra(intent, EXTRA_CHANNEL_DESCRIPTION, null);
        String title = extra(intent, EXTRA_TITLE, appName.toString());
        String text = extra(intent, EXTRA_TEXT, "Working in the background");
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW);
        if (channelDescription != null) {
            channel.setDescription(channelDescription);
        }
        manager.createNotificationChannel(channel);
        Notification notification = new Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(getApplicationInfo().icon != 0 ? getApplicationInfo().icon : android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        if (intent != null && intent.getBooleanExtra(EXTRA_STOP, false)) {
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        // A service the system stopped is not started again: the tasks it was for went with the process.
        return START_NOT_STICKY;
    }

    // The text of an Intent extra, or the fallback when the app supplied none.
    private static String extra(Intent intent, String name, String fallback) {
        String value = intent == null ? null : intent.getStringExtra(name);
        return value == null ? fallback : value;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
