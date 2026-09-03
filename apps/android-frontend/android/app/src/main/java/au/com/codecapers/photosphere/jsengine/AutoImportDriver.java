package au.com.codecapers.photosphere.jsengine;

//
// The background automatic import: one pass at a time, and a loop above it.
//
// A pass asks the plan-auto-import task what to do and runs the tasks it hands back, in order. The
// loop asks for a pass, waits for it, waits again for the gap the plan asked for, and asks for
// another, until a plan says automatic import is switched off or the driver is stopped.
//
// There is exactly one entry point that runs a pass, and it is serialised: asked to run while a pass
// is in flight, it waits for that pass and returns its outcome rather than starting a second. That is
// what makes two imports at once unreachable rather than merely unlikely. On Android only the loop
// asks; on iOS the foreground loop and the system's background task both ask, and neither knows about
// the other, because they do not have to.
//
// Nothing in this class touches Android, which is why the decisions it makes can be unit tested. The
// service supplies everything that does through the Host interface below.
//
public final class AutoImportDriver {

    //
    // The gap between passes when no plan has said what it should be, in milliseconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap that the
    // settings file resolves (see resolveAutoImportPauseMs in
    // packages/api/src/lib/auto-import-mobile.ts, which is where the value a running phone uses comes
    // from). It exists because a gap of zero is not a gap: the loop would ask for a pass, fail to
    // read a plan, and ask again as fast as the engine could answer.
    //
    private static final long FALLBACK_PAUSE_MS = 30000;

    //
    // What a finished pass says about what should happen next.
    //
    public enum PassOutcome {

        //
        // The pass ran (or tried to). Wait the gap and go again.
        //
        RAN,

        //
        // Automatic import is switched off. Stop.
        //
        STOP,
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
        // Runs the plan-auto-import task and returns what it says a pass should do. Throws when the
        // task fails, which the driver treats as a pass that did not work rather than as a reason to
        // give up.
        //
        AutoImportPlan readPlan() throws Exception;

        //
        // Runs one of the plan's steps and waits for it to finish. Returns true when it succeeded.
        //
        boolean runStep(AutoImportPlan.Step step) throws Exception;

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
        // and a wake lock held all night flattens the phone.
        //
        void holdAwake(boolean awake);

        //
        // Reports what the background import is doing. Goes to logcat on a device: the app log is
        // written over a socket from the WebView, which is suspended exactly when this matters.
        //
        void report(String message);

        //
        // Reports something that went wrong.
        //
        void reportError(String message);

        //
        // The loop has ended because automatic import is switched off. The service stops itself.
        //
        void onStopped();
    }

    //
    // Everything the driver needs that it cannot do itself.
    //
    private final Host host;

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
    // Constructs a driver over the given host.
    //
    public AutoImportDriver(Host host) {
        this.host = host;
    }

    //
    // Runs passes until a plan says automatic import is switched off, or until the driver is stopped.
    //
    // A pass that fails does not end the loop. The next one is scheduled anyway: an import can fail
    // for a reason that has since gone (no space at that moment, a file being written as it was read),
    // and giving up would leave automatic import switched on in the interface and doing nothing.
    //
    public void runLoop() {
        while (!stopped) {
            PassOutcome outcome;
            try {
                outcome = runOnePass();
            }
            catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }

            if (outcome == PassOutcome.STOP) {
                host.onStopped();
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
    // Asks what this pass should do and runs it.
    //
    private PassOutcome performPass() {
        AutoImportPlan plan;
        try {
            plan = host.readPlan();
        }
        catch (Exception error) {
            // A plan that cannot be read is not an answer of "switched off". Treating it as one would
            // stop automatic import for good over a single failed task, so the pass counts as run and
            // the next one asks again.
            host.reportError("Could not work out what automatic import should do: " + error);
            return PassOutcome.RAN;
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all, and
        // the wait it turns into on Android (Object.wait(0)) never ends.
        pauseMs = plan.pauseBetweenRunsMs > 0 ? plan.pauseBetweenRunsMs : FALLBACK_PAUSE_MS;

        if (!plan.shouldRun) {
            host.report("Automatic import is switched off.");
            return PassOutcome.STOP;
        }

        host.holdAwake(true);
        try {
            host.report("Automatic import running into \"" + plan.databasePath + "\".");

            for (AutoImportPlan.Step step : plan.steps) {
                if (stopped) {
                    return PassOutcome.RAN;
                }

                boolean succeeded;
                try {
                    succeeded = host.runStep(step);
                }
                catch (Exception error) {
                    host.reportError("Automatic import step \"" + step.type + "\" failed: " + error);
                    return PassOutcome.RAN;
                }

                if (!succeeded) {
                    // The rest of the pass is abandoned, not the loop: an import into a database
                    // that could not be created has nothing to import into, and the next pass
                    // starts from the plan again rather than from where this one gave up.
                    host.reportError("Automatic import step \"" + step.type + "\" did not succeed.");
                    return PassOutcome.RAN;
                }
            }
        }
        finally {
            host.holdAwake(false);
        }

        return PassOutcome.RAN;
    }
}
