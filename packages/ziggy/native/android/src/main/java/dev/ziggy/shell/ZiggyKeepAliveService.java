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
// when the core says the last such task has ended.
public final class ZiggyKeepAliveService extends Service {
    private static final String CHANNEL_ID = "ziggy-keep-alive";
    private static final int NOTIFICATION_ID = 0x5A01;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL_ID, "Background work", NotificationManager.IMPORTANCE_LOW));
        CharSequence appName = getApplicationInfo().loadLabel(getPackageManager());
        Notification notification = new Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(appName)
            .setContentText("Working in the background")
            .setSmallIcon(getApplicationInfo().icon != 0 ? getApplicationInfo().icon : android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .build();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIFICATION_ID, notification);
        }
        // A service the system stopped is not started again: the tasks it was for went with the process.
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
