package au.com.codecapers.photosphere.ziggy;

import android.content.Context;
import android.os.PowerManager;

// The wake lock the background work holds while a pass is running, so the CPU keeps working with the screen off. It is released
// between passes: held for the life of the service it would flatten a phone overnight.
//
// Reference counted, because the passes of the background loops overlap. Each takes a hold for its own pass and gives it back
// afterwards, and the phone is free to sleep when the last hold goes. Held with no timeout, because a first backup of a phone's whole
// photo library is over an hour of hashing and a timed lock would expire in the middle of it. A wake lock belongs to the process, so a
// process killed mid pass has its lock released by the platform.
public final class BackgroundWakeLock {
    // The wake lock tag, which appears in battery diagnostics.
    private static final String WAKE_LOCK_TAG = "photosphere:auto-import";

    private final Context context;

    private PowerManager.WakeLock wakeLock;

    public BackgroundWakeLock(Context context) {
        this.context = context;
    }

    // Takes one hold on the wake lock (awake true) or gives one back (awake false).
    public synchronized void hold(boolean awake) {
        if (awake) {
            if (wakeLock == null) {
                PowerManager powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
                if (powerManager == null) {
                    throw new IllegalStateException("This phone has no power manager to hold the CPU awake with.");
                }
                wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG);
                wakeLock.setReferenceCounted(true);
            }
            wakeLock.acquire();
            return;
        }
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }

    // Gives back every hold, for when the app is going away and the passes that took them will not give them back themselves.
    public synchronized void releaseAll() {
        while (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
    }
}
