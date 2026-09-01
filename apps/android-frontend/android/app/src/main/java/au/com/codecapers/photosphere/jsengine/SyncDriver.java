package au.com.codecapers.photosphere.jsengine;

//
// The background sync: one pass at a time, and a loop above it.
//
// A pass asks the plan-sync task whether a sync should run and runs the tasks it hands back, in
// order. The loop asks for a pass, waits for it, waits again for the gap the plan asked for, and asks
// for another, until the driver is stopped.
//
// Unlike the import loop, nothing a plan says ends this one. Every reason a sync is refused can go
// away without the app being touched: a phone moves onto Wi-Fi, a network comes back, a database gets
// an origin, the user switches syncing back on. A loop that ended on a refusal would need something
// to notice each of those and start it again, and the cost of getting that wrong is a phone that
// looks like it is backing up and is not. A refused pass costs a settings file read.
//
// There is exactly one entry point that runs a pass, and it is serialised: asked to run while a pass
// is in flight, it waits for that pass and returns its outcome rather than starting a second. On
// Android only the loop asks; on iOS the foreground loop and the system's background task both ask,
// and neither knows about the other, because they do not have to.
//
// A pass also takes the shared BackgroundPassLock, so a sync and an import never run at once. A pass
// that cannot take it is skipped and tried again after the usual gap.
//
// Nothing in this class touches Android, which is why the decisions it makes can be unit tested. The
// service supplies everything that does through the Host interface below.
//
public final class SyncDriver {

    //
    // The name this driver takes the shared pass lock under, so a skipped pass can say what it is
    // waiting behind.
    //
    public static final String PASS_LOCK_OWNER = "sync";

    //
    // The gap between passes when no plan has said what it should be, in milliseconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap that the
    // settings file resolves (see resolveSyncPauseMs in packages/api/src/lib/sync-settings.ts, which
    // is where the value a running phone uses comes from). It exists because a gap of zero is not a
    // gap: the loop would ask for a pass, fail to read a plan, and ask again as fast as the engine
    // could answer.
    //
    private static final long FALLBACK_PAUSE_MS = 5 * 60 * 1000;

    //
    // What a finished pass says about what should happen next.
    //
    public enum PassOutcome {

        //
        // The pass ran, was refused, or tried and failed. Wait the gap and go again. There is
        // deliberately no other value: nothing a pass discovers is a reason to stop syncing for good.
        //
        RAN,
    }

    //
    // Everything the driver needs that it cannot do itself: talking to the engine pool, waiting,
    // keeping the CPU awake, and saying what happened.
    //
    // It is an interface so the loop's decisions can be tested without an Android device, a running
    // engine, or a real clock.
    //
    public interface Host {

        //
        // Runs the plan-sync task and returns what it says a pass should do. Throws when the task
        // fails, which the driver treats as a pass that did not work rather than as a reason to give
        // up.
        //
        SyncPlan readPlan() throws Exception;

        //
        // Runs one of the plan's steps and waits for it to finish. Returns true when it succeeded.
        //
        boolean runStep(SyncPlan.Step step) throws Exception;

        //
        // Waits for the given number of milliseconds, or until the driver is stopped. Returns false
        // when the wait was cut short by a stop, so the loop ends instead of starting another pass.
        //
        boolean pause(long millis) throws InterruptedException;

        //
        // Keeps the CPU running while a pass is in flight, and lets it sleep again afterwards.
        //
        // Held for the length of a pass rather than the life of the service, because a foreground
        // service keeps the process alive but does not keep the CPU awake once the screen is off,
        // and a wake lock held all night flattens the phone. A sync pass is shorter than an import
        // pass, but a sync of a large backlog over a slow connection is not short.
        //
        void holdAwake(boolean awake);

        //
        // Reports what the background sync is doing. Goes to logcat on a device: the app log is
        // written over a socket from the WebView, which is suspended exactly when this matters.
        //
        void report(String message);

        //
        // Reports something that went wrong.
        //
        void reportError(String message);
    }

    //
    // Everything the driver needs that it cannot do itself.
    //
    private final Host host;

    //
    // The lock that keeps a sync pass and an import pass apart.
    //
    private final BackgroundPassLock sharedPassLock;

    //
    // Guards the pass bookkeeping below, and is what a second caller waits on while a pass runs.
    //
    private final Object passLock = new Object();

    //
    // True while a pass is in flight, so a second request waits for it rather than starting another.
    //
    private boolean passRunning = false;

    //
    // What the pass that just finished decided, handed to anyone who waited for it.
    //
    private PassOutcome lastOutcome = PassOutcome.RAN;

    //
    // True once the driver has been stopped. A stopped driver runs no further passes and its loop
    // ends at the next opportunity.
    //
    private volatile boolean stopped = false;

    //
    // How long to wait before the next pass, as the last plan asked. Read by the loop after the pass
    // that set it, so the gap comes from the settings file rather than from a constant here.
    //
    private volatile long pauseMs = FALLBACK_PAUSE_MS;

    //
    // Constructs a driver over the given host, sharing the given pass lock with the import driver.
    //
    public SyncDriver(Host host, BackgroundPassLock sharedPassLock) {
        this.host = host;
        this.sharedPassLock = sharedPassLock;
    }

    //
    // Runs passes until the driver is stopped.
    //
    // A pass that fails does not end the loop. Sync has more reasons to fail than import does, not
    // fewer: no network, a remote that is briefly unreachable, an expired credential. Every one of
    // them can be gone by the next pass, and giving up would leave syncing switched on in the
    // interface and doing nothing.
    //
    public void runLoop() {
        while (!stopped) {
            try {
                runOnePass();
            }
            catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }

            if (stopped) {
                return;
            }

            try {
                if (!host.pause(pauseMs)) {
                    return;
                }
            }
            catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    //
    // Runs one pass, or waits for the one already running and reports what it decided.
    //
    // This is the only way a pass starts, on either platform. Two passes at once is not a state the
    // code can reach, so nothing anywhere has to stop one before starting another.
    //
    public PassOutcome runOnePass() throws InterruptedException {
        synchronized (passLock) {
            if (passRunning) {
                while (passRunning) {
                    passLock.wait();
                }
                return lastOutcome;
            }
            passRunning = true;
        }

        PassOutcome outcome = PassOutcome.RAN;
        try {
            outcome = performPass();
        }
        finally {
            synchronized (passLock) {
                passRunning = false;
                lastOutcome = outcome;
                passLock.notifyAll();
            }
        }

        return outcome;
    }

    //
    // Stops the driver: no further passes start, and a loop waiting between passes ends rather than
    // running another. A pass already in flight is left to finish; the engine pool cancels the tasks
    // it queued by source, which is what actually stops the work.
    //
    public void stop() {
        stopped = true;
    }

    //
    // True once the driver has been stopped.
    //
    public boolean isStopped() {
        return stopped;
    }

    //
    // Asks whether a sync should run and runs it.
    //
    private PassOutcome performPass() {
        SyncPlan plan;
        try {
            plan = host.readPlan();
        }
        catch (Exception error) {
            // A plan that cannot be read is not an answer of "do not sync". The pass counts as run
            // and the next one asks again.
            host.reportError("Could not work out whether a sync should run: " + error);
            return PassOutcome.RAN;
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all, and
        // the wait it turns into on Android (Object.wait(0)) never ends.
        pauseMs = plan.pauseBetweenRunsMs > 0 ? plan.pauseBetweenRunsMs : FALLBACK_PAUSE_MS;

        if (!plan.shouldRun) {
            host.report("Not syncing: " + plan.reason);
            return PassOutcome.RAN;
        }

        if (!sharedPassLock.tryAcquire(PASS_LOCK_OWNER)) {
            // An import pass is in flight. Skipped rather than waited for: an import of a whole photo
            // library runs for the better part of an hour, and the sync it is holding up is one that
            // will be asked for again in a few minutes anyway.
            host.report("Not syncing yet: an import pass is running.");
            return PassOutcome.RAN;
        }

        try {
            host.holdAwake(true);
            try {
                host.report("Syncing \"" + plan.databasePath + "\".");

                for (SyncPlan.Step step : plan.steps) {
                    if (stopped) {
                        return PassOutcome.RAN;
                    }

                    boolean succeeded;
                    try {
                        succeeded = host.runStep(step);
                    }
                    catch (Exception error) {
                        host.reportError("Sync step \"" + step.type + "\" failed: " + error);
                        return PassOutcome.RAN;
                    }

                    if (!succeeded) {
                        // The rest of the pass is abandoned, not the loop, and the next pass starts
                        // from the plan again rather than from where this one gave up.
                        host.reportError("Sync step \"" + step.type + "\" did not succeed.");
                        return PassOutcome.RAN;
                    }
                }
            }
            finally {
                host.holdAwake(false);
            }
        }
        finally {
            sharedPassLock.release(PASS_LOCK_OWNER);
        }

        return PassOutcome.RAN;
    }
}
