package au.com.codecapers.photosphere.jsengine;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

//
// The foreground service that keeps automatic import working while the app is off screen.
//
// Automatic import used to be driven by a timer in the WebView, which is throttled and then stopped
// by the operating system the moment the app is backgrounded and the screen goes off. A foreground
// service is the platform's answer to work that has to carry on regardless, and the price of it is
// the ongoing notification below, which the platform requires and the user will see for as long as
// automatic import is switched on.
//
// The service owns no decisions. It hosts an AutoImportDriver, hands it the engine pool through the
// plugin, and stops itself when the driver reports that automatic import has been switched off. It is
// started only by the app, and only once the user has switched automatic import on: a phone that has
// not opted in never runs it and never sees its notification.
//
public final class AutoImportService extends Service {

    //
    // Log tag for service diagnostics. These go to logcat rather than the app log, which is written
    // over a socket from the WebView and is suspended exactly when this service matters most.
    //
    private static final String LOG_TAG = "AutoImportService";

    //
    // The notification channel the ongoing notification is posted on.
    //
    private static final String NOTIFICATION_CHANNEL_ID = "photosphere-auto-import";

    //
    // The notification id. Fixed: there is only ever one of these, and posting it again replaces it.
    //
    private static final int NOTIFICATION_ID = 1;

    //
    // The wake lock tag, which appears in battery diagnostics.
    //
    private static final String WAKE_LOCK_TAG = "photosphere:auto-import";

    //
    // The thread the driver's loop runs on, so the service's main thread is never blocked.
    //
    private Thread loopThread;

    //
    // The driver running the passes, or null when the service has not started one.
    //
    private AutoImportDriver driver;

    //
    // The wake lock held while a pass is in flight.
    //
    private PowerManager.WakeLock wakeLock;

    //
    // What the driver waits on between passes, so stopping the service ends the wait instead of
    // letting it run to the end of the gap.
    //
    private final Object pauseLock = new Object();

    //
    // Starts the service: posts the ongoing notification, then starts the loop on its own thread.
    //
    // START_NOT_STICKY, deliberately. The engine pool the passes run on belongs to the Capacitor
    // plugin and is built from the Activity's context, so a service the system restarts on its own,
    // in a process with no Activity in it, has nothing to run a pass on: it would loop failing every
    // pass and posting a notification saying photos were being backed up while none were. A killed
    // process therefore stops importing until the app is opened again, and opening it starts the
    // service back up, which is what the provider does when it finds automatic import switched on.
    //
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, buildNotification());

        if (!JsEnginePlugin.isLoaded()) {
            // Nothing to run passes on. Said out loud and stopped, rather than left running and
            // failing quietly behind a notification that claims otherwise.
            Log.i(LOG_TAG, "The JsEngine plugin is not loaded, so there is nothing to import with. Stopping.");
            stopSelf();
            return START_NOT_STICKY;
        }

        if (loopThread != null) {
            // Already running. Starting it again must not start a second loop: two loops would ask
            // for a pass each, and while the driver would refuse to run them at once, they would take
            // turns running passes back to back with no gap between them.
            return START_NOT_STICKY;
        }

        final AutoImportDriver startedDriver = new AutoImportDriver(new ServiceHost());
        driver = startedDriver;

        loopThread = new Thread(new Runnable() {
            @Override
            public void run() {
                startedDriver.runLoop();
            }
        }, "photosphere-auto-import");
        loopThread.start();

        return START_NOT_STICKY;
    }

    //
    // Stops the loop and releases the wake lock. Called when the service is stopped, whether by the
    // app switching automatic import off or by the system.
    //
    @Override
    public void onDestroy() {
        if (driver != null) {
            driver.stop();
        }

        // Wake whatever is waiting between passes, so the loop ends now rather than at the end of the
        // gap it was part way through.
        synchronized (pauseLock) {
            pauseLock.notifyAll();
        }

        releaseWakeLock();

        JsEnginePlugin.releaseBackgroundImportHold();

        // The driver and the thread are deliberately not cleared. The loop thread is still reading
        // the driver to find out it has been stopped, and a service that is started again gets a
        // fresh instance of this class with fresh fields anyway.

        super.onDestroy();
    }

    //
    // Nothing binds to this service: it is started and stopped, not called into.
    //
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    //
    // Builds the ongoing notification the platform requires of a foreground service.
    //
    // It says what is happening rather than only that something is: an unexplained permanent
    // notification is the kind of thing a user switches an app off over.
    //
    private Notification buildNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Automatic photo import",
                NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Shown while your photos are being backed up in the background.");
            NotificationManager notificationManager = getSystemService(NotificationManager.class);
            if (notificationManager != null) {
                notificationManager.createNotificationChannel(channel);
            }
        }

        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            ? new Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            : new Notification.Builder(this);

        return builder
            .setContentTitle("Backing up your photos")
            .setContentText("Photosphere is importing new photos in the background.")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build();
    }

    //
    // Takes the wake lock, so a pass keeps working once the screen goes off.
    //
    private void acquireWakeLock() {
        if (wakeLock == null) {
            PowerManager powerManager = (PowerManager)getSystemService(Context.POWER_SERVICE);
            if (powerManager == null) {
                return;
            }
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG);
            wakeLock.setReferenceCounted(false);
        }

        if (!wakeLock.isHeld()) {
            // Held for as long as the pass takes, with no timeout on it. A first backup of a phone's
            // whole photo library is over an hour of hashing (see docs/performance/mobile-auto-import-scan.md),
            // and a timed lock would expire in the middle of it and let the CPU sleep with the screen
            // off, which is the one thing this service exists to prevent. There is nothing to guard
            // against by timing it out: a wake lock belongs to the process, so a process killed mid
            // pass has its lock released by the platform.
            wakeLock.acquire();
        }
    }

    //
    // Lets the phone sleep again.
    //
    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }

    //
    // Everything the driver needs that is Android's business: the engine pool, waiting, the wake
    // lock, logcat, and stopping the service.
    //
    private final class ServiceHost implements AutoImportDriver.Host {

        //
        // Asks the plan-auto-import task what this pass should do.
        //
        @Override
        public AutoImportPlan readPlan() throws Exception {
            return JsEnginePlugin.readBackgroundImportPlan();
        }

        //
        // Runs one of the plan's steps on the engine pool and waits for it to finish.
        //
        @Override
        public boolean runStep(AutoImportPlan.Step step) throws Exception {
            return JsEnginePlugin.runBackgroundImportStep(step);
        }

        //
        // Waits between passes, ending early when the service is stopped.
        //
        @Override
        public boolean pause(long millis) throws InterruptedException {
            synchronized (pauseLock) {
                pauseLock.wait(millis);
            }
            return driver != null && !driver.isStopped();
        }

        //
        // Keeps the CPU running for the length of a pass.
        //
        @Override
        public void holdAwake(boolean awake) {
            if (awake) {
                acquireWakeLock();
            }
            else {
                releaseWakeLock();
            }
        }

        //
        // Says what the background import is doing, in logcat.
        //
        @Override
        public void report(String message) {
            Log.i(LOG_TAG, message);
        }

        //
        // Says what went wrong, in logcat.
        //
        @Override
        public void reportError(String message) {
            Log.e(LOG_TAG, message);
        }

        //
        // Automatic import has been switched off, so the service takes its notification down and
        // stops. Nothing is left behind, which is what "switching it off leaves no trace" means.
        //
        @Override
        public void onStopped() {
            Log.i(LOG_TAG, "Automatic import is switched off, stopping the background import.");
            stopSelf();
        }
    }
}
