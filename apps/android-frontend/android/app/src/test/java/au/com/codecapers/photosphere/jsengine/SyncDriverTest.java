package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

//
// Plain-JVM unit tests for the background sync's decisions.
//
// The driver holds every decision the foreground service's sync loop makes, and holds no Android at
// all, which is what lets these run on the JVM: the service supplies the engine pool, the clock, the
// wake lock and logcat through the Host interface, and a recording double supplies them here.
//
public final class SyncDriverTest {

    //
    // A plan with one sync step, which is what an ordinary pass looks like.
    //
    private static SyncPlan runningPlan(long pauseMs) {
        return new SyncPlan(
            true,
            "photosphere-default",
            "",
            pauseMs,
            Collections.singletonList(new SyncPlan.Step("sync-database", "{}")));
    }

    //
    // A plan that says no sync should run, with the reason the log would carry.
    //
    private static SyncPlan refusedPlan(String reason, long pauseMs) {
        return new SyncPlan(false, "", reason, pauseMs, new ArrayList<SyncPlan.Step>());
    }

    //
    // A host that answers with the plans it is given, records what it was asked to do, and never
    // really waits.
    //
    private static class RecordingHost implements SyncDriver.Host {

        //
        // The plans handed out, one per pass, the last one repeating once they run out.
        //
        private final List<SyncPlan> plans;

        //
        // The step types that failed rather than succeeded.
        //
        private final List<String> failingStepTypes;

        //
        // The step types that throw rather than returning at all.
        //
        private final List<String> throwingStepTypes;

        //
        // How many plans have been asked for.
        //
        final AtomicInteger plansRead = new AtomicInteger(0);

        //
        // The steps that were run, in order.
        //
        final List<String> stepsRun = Collections.synchronizedList(new ArrayList<String>());

        //
        // The gaps that were waited, in order.
        //
        final List<Long> pauses = Collections.synchronizedList(new ArrayList<Long>());

        //
        // How many times the wake lock was taken and given back.
        //
        final AtomicInteger wakeLocksTaken = new AtomicInteger(0);
        final AtomicInteger wakeLocksReleased = new AtomicInteger(0);

        //
        // Everything reported, so a test can check a refusal says why.
        //
        final List<String> reports = Collections.synchronizedList(new ArrayList<String>());

        //
        // Set to end the loop from inside a pause, standing in for the service being stopped.
        //
        volatile SyncDriver driverToStopWhilePaused = null;

        //
        // Set to throw from readPlan, standing in for the plan-sync task failing.
        //
        volatile boolean planReadThrows = false;

        //
        // Constructs a host answering with the given plans.
        //
        RecordingHost(List<SyncPlan> plans, List<String> failingStepTypes, List<String> throwingStepTypes) {
            this.plans = plans;
            this.failingStepTypes = failingStepTypes;
            this.throwingStepTypes = throwingStepTypes;
        }

        @Override
        public SyncPlan readPlan() throws Exception {
            int index = plansRead.getAndIncrement();
            if (planReadThrows) {
                throw new Exception("the plan-sync task failed");
            }
            return plans.get(Math.min(index, plans.size() - 1));
        }

        @Override
        public boolean runStep(SyncPlan.Step step) throws Exception {
            stepsRun.add(step.type);
            if (throwingStepTypes.contains(step.type)) {
                throw new Exception("the sync task threw");
            }
            return !failingStepTypes.contains(step.type);
        }

        @Override
        public boolean pause(long millis) {
            pauses.add(millis);
            if (driverToStopWhilePaused != null) {
                driverToStopWhilePaused.stop();
                return false;
            }
            return true;
        }

        @Override
        public void holdAwake(boolean awake) {
            if (awake) {
                wakeLocksTaken.incrementAndGet();
            }
            else {
                wakeLocksReleased.incrementAndGet();
            }
        }

        @Override
        public void report(String message) {
            reports.add(message);
        }

        @Override
        public void reportError(String message) {
            reports.add(message);
        }
    }

    //
    // A host answering with one plan forever, with no failures.
    //
    private static RecordingHost hostAnswering(SyncPlan plan) {
        return new RecordingHost(
            Collections.singletonList(plan),
            Collections.<String>emptyList(),
            Collections.<String>emptyList());
    }

    @Test
    public void aPassRunsTheStepsThePlanAsksFor() throws Exception {
        RecordingHost host = hostAnswering(runningPlan(1000));
        SyncDriver driver = new SyncDriver(host);

        driver.runOnePass();

        assertEquals(Arrays.asList("sync-database"), host.stepsRun);
    }

    @Test
    public void aRefusedPassRunsNothingAndSaysWhy() throws Exception {
        RecordingHost host = hostAnswering(refusedPlan("syncing is switched off", 1000));
        SyncDriver driver = new SyncDriver(host);

        driver.runOnePass();

        assertTrue("a refused pass must run no steps", host.stepsRun.isEmpty());
        assertTrue("the reason must reach the log", host.reports.toString().contains("syncing is switched off"));
    }

    @Test
    public void aRefusedPassDoesNotEndTheLoop() throws Exception {
        // Every reason a sync is refused can go away without the app being touched: a phone moves
        // onto Wi-Fi, a network comes back, the user switches syncing on again. A loop that ended
        // here would need something to notice each of those and start it again.
        RecordingHost host = hostAnswering(refusedPlan("the connection is \"cellular\"", 1000));
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertTrue("the loop must have gone on to wait for the next pass", host.pauses.size() >= 1);
        assertTrue("the loop must have ended by being stopped", driver.isStopped());
    }

    @Test
    public void aFailedStepDoesNotEndTheLoop() throws Exception {
        // Sync has more reasons to fail than import does, not fewer: no network, a remote that is
        // briefly unreachable, an expired credential. Every one of them can be gone by the next pass.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1000)),
            Collections.singletonList("sync-database"),
            Collections.<String>emptyList());
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals("the failed pass must still be followed by a wait", 1, host.pauses.size());
    }

    @Test
    public void aStepThatThrowsDoesNotEndTheLoop() throws Exception {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1000)),
            Collections.<String>emptyList(),
            Collections.singletonList("sync-database"));
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals("the failed pass must still be followed by a wait", 1, host.pauses.size());
    }

    @Test
    public void aPlanThatCannotBeReadDoesNotEndTheLoop() throws Exception {
        RecordingHost host = hostAnswering(runningPlan(1000));
        host.planReadThrows = true;
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertTrue("a plan that cannot be read must not stop syncing for good", host.pauses.size() >= 1);
    }

    @Test
    public void stoppingEndsTheLoop() throws Exception {
        RecordingHost host = hostAnswering(runningPlan(1000));
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertTrue(driver.isStopped());
        assertEquals("the loop must have run exactly one pass before it was stopped", 1, host.plansRead.get());
    }

    @Test
    public void theGapComesFromThePlanRatherThanFromTheDriver() throws Exception {
        RecordingHost host = hostAnswering(runningPlan(90000));
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals(Long.valueOf(90000), host.pauses.get(0));
    }

    @Test
    public void aGapOfZeroIsRefusedRatherThanWaitedOn() throws Exception {
        // Object.wait(0) never ends, so a plan asking for no gap at all would park the loop forever
        // rather than making it fast.
        RecordingHost host = hostAnswering(runningPlan(0));
        SyncDriver driver = new SyncDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertTrue("the gap must have been replaced with a real one", host.pauses.get(0) > 0);
    }

    @Test
    public void theWakeLockIsHeldForThePassAndGivenBackAfterIt() throws Exception {
        RecordingHost host = hostAnswering(runningPlan(1000));
        SyncDriver driver = new SyncDriver(host);

        driver.runOnePass();

        assertEquals(1, host.wakeLocksTaken.get());
        assertEquals(1, host.wakeLocksReleased.get());
    }

    @Test
    public void aRefusedPassDoesNotTakeTheWakeLock() throws Exception {
        // A phone that is not syncing must not be kept awake to find that out.
        RecordingHost host = hostAnswering(refusedPlan("syncing is switched off", 1000));
        SyncDriver driver = new SyncDriver(host);

        driver.runOnePass();

        assertEquals(0, host.wakeLocksTaken.get());
    }

    @Test
    public void aSecondRequestWaitsForThePassInFlightRatherThanStartingAnother() throws Exception {
        // On iOS the foreground loop and the system's background task both ask, and neither knows
        // about the other. Two passes at once has to be unreachable rather than unlikely.
        final CountDownLatch stepStarted = new CountDownLatch(1);
        final CountDownLatch stepMayFinish = new CountDownLatch(1);

        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1000)),
            Collections.<String>emptyList(),
            Collections.<String>emptyList()) {

            @Override
            public boolean runStep(SyncPlan.Step step) {
                stepsRun.add(step.type);
                stepStarted.countDown();
                try {
                    stepMayFinish.await(5, TimeUnit.SECONDS);
                }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
                return true;
            }
        };

        final SyncDriver driver = new SyncDriver(host);

        Thread firstCaller = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    driver.runOnePass();
                }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        firstCaller.start();

        assertTrue("the first pass should have started", stepStarted.await(5, TimeUnit.SECONDS));

        Thread secondCaller = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    driver.runOnePass();
                }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        secondCaller.start();

        // Give the second caller time to get as far as it is going to get, which must be waiting
        // rather than running a pass of its own.
        Thread.sleep(200);
        assertEquals("the second request must not start a second pass", 1, host.stepsRun.size());

        stepMayFinish.countDown();
        firstCaller.join(5000);
        secondCaller.join(5000);

        assertEquals("only one pass may ever have run", 1, host.stepsRun.size());
    }

    @Test
    public void aSyncPassRunsWhileAnImportPassIsInFlight() throws Exception {
        // The two loops used to take one shared lock around a whole pass, so a sync skipped its pass
        // whenever an import was running. Measured against a real library on a Pixel 6, 2,292 assets,
        // that meant no sync at all: one import pass ran for over half an hour and the next started
        // seconds after it, so the sync loop skipped every pass and pushed nothing.
        final CountDownLatch importStepStarted = new CountDownLatch(1);
        final CountDownLatch importStepMayFinish = new CountDownLatch(1);

        AutoImportDriver.Host importHost = new AutoImportDriver.Host() {

            @Override
            public AutoImportPlan readPlan() {
                return new AutoImportPlan(
                    true,
                    "photosphere-default",
                    1000,
                    Collections.singletonList(new AutoImportPlan.Step("import-assets", "{}")));
            }

            @Override
            public boolean runStep(AutoImportPlan.Step step) throws Exception {
                importStepStarted.countDown();
                return importStepMayFinish.await(5, TimeUnit.SECONDS);
            }

            @Override
            public boolean pause(long millis) {
                return false;
            }

            @Override
            public void holdAwake(boolean awake) {
            }

            @Override
            public void report(String message) {
            }

            @Override
            public void reportError(String message) {
            }

            @Override
            public void onStopped() {
            }
        };

        final AutoImportDriver importDriver = new AutoImportDriver(importHost);

        Thread importThread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    importDriver.runOnePass();
                }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        });
        importThread.start();

        assertTrue("the import pass should have started", importStepStarted.await(5, TimeUnit.SECONDS));

        // The import pass is held open at its step, and the sync pass runs to completion anyway.
        RecordingHost syncHost = hostAnswering(runningPlan(1000));
        SyncDriver syncDriver = new SyncDriver(syncHost);

        syncDriver.runOnePass();

        assertEquals("the sync must have run its step while the import pass was still in flight",
            Arrays.asList("sync-database"), syncHost.stepsRun);

        importStepMayFinish.countDown();
        importThread.join(5000);
    }
}
