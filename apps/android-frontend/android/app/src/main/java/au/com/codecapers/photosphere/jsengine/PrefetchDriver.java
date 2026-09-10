package au.com.codecapers.photosphere.jsengine;

//
// The background prefetch: one pass at a time, and a loop above it.
//
// A pass asks the plan-prefetch task what to do and runs the tasks it hands back, in order. The loop
// asks for a pass, waits for it, waits again for the gap the plan asked for, and asks for another,
// until a pass reports that the replica has nothing left missing or the driver is stopped.
//
// It exists because the only thing that ever queued a prefetch was the end of a load-assets run, so a
// prefetch that failed part way was never tried again, and a sync cannot repair the replica it left
// behind: a sync copies what the difference between two merkle trees shows, and a partial replica's
// tree already matches its origin's, so a missing file is invisible to it. Measured on a Pixel 6, a
// prefetch died 38 minutes in with every thumbnail fetched and the database index files missing, and
// nothing ever started another.
//
// Modelled on AutoImportDriver rather than SyncDriver, because this loop ends itself. A sync has
// reasons to refuse that go away on their own, so it asks for ever. A prefetch that has fetched
// everything has nothing left to do, and asking again means walking every object at the origin every
// gap, which on a real library is thousands of listings and thousands of local existence checks.
// Stopping and being started again when a database is opened is cheaper and is the same shape the
// import loop already has.
//
// There is exactly one entry point that runs a pass, and it is serialised: asked to run while a pass
// is in flight, it waits for that pass and returns its outcome rather than starting a second.
//
// Nothing in this class touches Android, which is why the decisions it makes can be unit tested. The
// service supplies everything that does through the Host interface below.
//
public final class PrefetchDriver {

    //
    // The gap between passes when no plan has said what it should be, in milliseconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap that the
    // settings file resolves. It exists because a gap of zero is not a gap: the loop would ask for a
    // pass, fail to read a plan, and ask again as fast as the engine could answer.
    //
    private static final long FALLBACK_PAUSE_MS = 30000;

    //
    // What a finished pass says about what should happen next.
    //
    public enum PassOutcome {

        //
        // The pass ran (or tried to), and there may be more to do. Wait the gap and go again.
        //
        RAN,

        //
        // The replica is complete: the pass fetched nothing and found nothing missing. Stop, and be
        // started again when a database is opened.
        //
        STOP,
    }

    //
    // What running one step did, which is the whole of what the loop decides on.
    //
    // A carrier rather than a number, because "it worked" and "how much was left" are separate
    // answers and a single int cannot say both: zero files fetched is what a complete replica and a
    // failed pass both look like from the outside, and they lead to opposite decisions.
    //
    public static final class StepResult {

        //
        // Whether the step succeeded. A step that failed leaves the loop running, because the file
        // that would not copy is tried again on the next pass.
        //
        public final boolean succeeded;

        //
        // How many files the step copied down from the origin.
        //
        public final int filesFetched;

        //
        // How many files the step found missing and did not copy.
        //
        public final int filesStillMissing;

        //
        // Constructs a result. All three fields are required and final.
        //
        public StepResult(boolean succeeded, int filesFetched, int filesStillMissing) {
            this.succeeded = succeeded;
            this.filesFetched = filesFetched;
            this.filesStillMissing = filesStillMissing;
        }
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
        // Runs the plan-prefetch task and returns what it says a pass should do. Throws when the task
        // fails, which the driver treats as a pass that did not work rather than as a reason to give
        // up.
        //
        PrefetchPlan readPlan() throws Exception;

        //
        // Runs one of the plan's steps and waits for it to finish, reporting what it did.
        //
        StepResult runStep(PrefetchPlan.Step step) throws Exception;

        //
        // Waits for the given number of milliseconds, or until the driver is stopped. Returns false
        // when the wait was cut short by a stop, so the loop ends instead of starting another pass.
        //
        boolean pause(long millis) throws InterruptedException;

        //
        // Keeps the CPU running while a pass is in flight, and lets it sleep again afterwards.
        //
        // Held for the length of a pass rather than the life of the service, because a foreground
        // service keeps the process alive but does not keep the CPU awake once the screen is off, and
        // a wake lock held all night flattens the phone.
        //
        void holdAwake(boolean awake);

        //
        // Reports what the background prefetch is doing. Goes to logcat on a device: the app log is
        // written over a socket from the WebView, which is suspended exactly when this matters.
        //
        void report(String message);

        //
        // Reports something that went wrong.
        //
        void reportError(String message);

        //
        // The loop has ended because the replica is complete. The service leaves its other loops
        // running; only this one is finished.
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
    public PrefetchDriver(Host host) {
        this.host = host;
    }

    //
    // Runs passes until one reports the replica complete, or until the driver is stopped.
    //
    // A pass that fails does not end the loop. The next one is scheduled anyway: a file can fail to
    // copy for a reason that has since gone, and this loop exists precisely because a prefetch that
    // gave up was never tried again.
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
        PrefetchPlan plan;
        try {
            plan = host.readPlan();
        }
        catch (Exception error) {
            // A plan that cannot be read is not an answer of "nothing left to fetch". Treating it as
            // one would stop the loop for good over a single failed task, so the pass counts as run
            // and the next one asks again.
            host.reportError("Could not work out what the background prefetch should do: " + error);
            return PassOutcome.RAN;
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all, and
        // the wait it turns into on Android (Object.wait(0)) never ends.
        pauseMs = plan.pauseBetweenRunsMs > 0 ? plan.pauseBetweenRunsMs : FALLBACK_PAUSE_MS;

        if (!plan.shouldRun) {
            // Refused, not finished. The loop keeps asking, because everything that refuses a pass
            // can stop refusing without the app being touched.
            host.report("No database to fill in: " + plan.reason);
            return PassOutcome.RAN;
        }

        host.holdAwake(true);
        try {
            host.report("Filling in \"" + plan.databasePath + "\".");

            boolean anythingLeft = false;
            boolean anythingFetched = false;

            for (PrefetchPlan.Step step : plan.steps) {
                if (stopped) {
                    return PassOutcome.RAN;
                }

                StepResult result;
                try {
                    result = host.runStep(step);
                }
                catch (Exception error) {
                    host.reportError("Prefetch step \"" + step.type + "\" failed: " + error);
                    return PassOutcome.RAN;
                }

                if (!result.succeeded) {
                    // The loop keeps going, which is what makes a failed prefetch retry, and is the
                    // whole reason this loop exists.
                    host.reportError("Prefetch step \"" + step.type + "\" did not succeed.");
                    return PassOutcome.RAN;
                }

                if (result.filesFetched > 0) {
                    anythingFetched = true;
                }
                if (result.filesStillMissing > 0) {
                    anythingLeft = true;
                }
            }

            if (!anythingFetched && !anythingLeft) {
                // Nothing fetched and nothing missing: the replica is complete and there is nothing
                // left to walk. Opening a database queues a prefetch again, which is what starts this
                // loop over when there is a reason to.
                host.report("\"" + plan.databasePath + "\" is filled in; nothing left to fetch.");
                return PassOutcome.STOP;
            }
        }
        finally {
            host.holdAwake(false);
        }

        return PassOutcome.RAN;
    }
}
