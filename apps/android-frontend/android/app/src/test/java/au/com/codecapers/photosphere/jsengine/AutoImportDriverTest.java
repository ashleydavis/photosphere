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
// Plain-JVM unit tests for the background automatic import's decisions.
//
// The driver holds every decision the foreground service makes, and holds no Android at all, which
// is what lets these run on the JVM: the service supplies the engine pool, the clock, the wake lock
// and logcat through the Host interface, and a recording double supplies them here.
//
public final class AutoImportDriverTest {

    //
    // A plan with one import step, which is what an ordinary pass looks like.
    //
    private static AutoImportPlan runningPlan(long pauseMs) {
        return new AutoImportPlan(
            true,
            "photosphere-default",
            pauseMs,
            Collections.singletonList(new AutoImportPlan.Step("import-assets", "{}")));
    }

    //
    // A plan that says automatic import is switched off.
    //
    private static AutoImportPlan stoppedPlan() {
        return new AutoImportPlan(false, "", 0, new ArrayList<AutoImportPlan.Step>());
    }

    //
    // A host that answers with the plans it is given, records what it was asked to do, and never
    // really waits.
    //
    private static class RecordingHost implements AutoImportDriver.Host {

        //
        // The plans handed out, one per pass, the last one repeating once they run out.
        //
        private final List<AutoImportPlan> plans;

        //
        // The step types that failed rather than succeeded.
        //
        private final List<String> failingStepTypes;

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
        // True once the driver reported that automatic import is switched off.
        //
        volatile boolean stoppedReported = false;

        //
        // Set to end the loop from inside a pause, standing in for the service being stopped.
        //
        volatile AutoImportDriver driverToStopWhilePaused = null;

        //
        // Constructs a host answering with the given plans.
        //
        RecordingHost(List<AutoImportPlan> plans, List<String> failingStepTypes) {
            this.plans = plans;
            this.failingStepTypes = failingStepTypes;
        }

        @Override
        public AutoImportPlan readPlan() {
            int index = plansRead.getAndIncrement();
            return plans.get(Math.min(index, plans.size() - 1));
        }

        @Override
        public boolean runStep(AutoImportPlan.Step step) {
            stepsRun.add(step.type);
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
        }

        @Override
        public void reportError(String message) {
        }

        @Override
        public void onStopped() {
            stoppedReported = true;
        }
    }

    @Test
    public void aPlanThatSaysOffStopsTheService() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(stoppedPlan()),
            Collections.<String>emptyList());
        AutoImportDriver driver = new AutoImportDriver(host);

        driver.runLoop();

        assertTrue("the service should be told to stop", host.stoppedReported);
        assertTrue("no step should run when automatic import is off", host.stepsRun.isEmpty());
        assertTrue("nothing should be waited for when the loop is over", host.pauses.isEmpty());
    }

    @Test
    public void aPassRunsEveryStepThePlanGives() throws Exception {
        AutoImportPlan plan = new AutoImportPlan(
            true,
            "photosphere-default",
            1,
            Arrays.asList(
                new AutoImportPlan.Step("create-database", "{}"),
                new AutoImportPlan.Step("record-default-database", "{}"),
                new AutoImportPlan.Step("import-assets", "{}")));
        RecordingHost host = new RecordingHost(
            Collections.singletonList(plan),
            Collections.<String>emptyList());
        AutoImportDriver driver = new AutoImportDriver(host);

        assertEquals(AutoImportDriver.PassOutcome.RAN, driver.runOnePass());

        assertEquals(
            Arrays.asList("create-database", "record-default-database", "import-assets"),
            host.stepsRun);
    }

    @Test
    public void aFailedStepAbandonsTheRestOfThePassButNotTheLoop() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(new AutoImportPlan(
                true,
                "photosphere-default",
                7,
                Arrays.asList(
                    new AutoImportPlan.Step("create-database", "{}"),
                    new AutoImportPlan.Step("import-assets", "{}")))),
            Collections.singletonList("create-database"));
        AutoImportDriver driver = new AutoImportDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals("the import must not run against a database that was not created",
            Collections.singletonList("create-database"), host.stepsRun);
        assertEquals("the next pass is still scheduled after a failure",
            Collections.singletonList(7L), host.pauses);
        assertFalse("a failed pass is not the same as automatic import being switched off",
            host.stoppedReported);
    }

    @Test
    public void aPlanThatCannotBeReadDoesNotEndTheLoop() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(3)),
            Collections.<String>emptyList()) {

            @Override
            public AutoImportPlan readPlan() {
                plansRead.incrementAndGet();
                throw new IllegalStateException("the engine is not there");
            }
        };
        AutoImportDriver driver = new AutoImportDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a failed plan read must not be taken as automatic import being switched off",
            host.stoppedReported);
        assertEquals("the loop keeps going and asks again", 1, host.pauses.size());
    }

    @Test
    public void stoppingBetweenPassesEndsTheLoop() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(5)),
            Collections.<String>emptyList());
        AutoImportDriver driver = new AutoImportDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals("exactly one pass runs before the stop", 1, host.plansRead.get());
        assertEquals("and it waits once before finding out it has been stopped", 1, host.pauses.size());
        assertTrue("the driver reports itself stopped", driver.isStopped());
        assertFalse("stopping is not the same as automatic import being switched off",
            host.stoppedReported);
    }

    @Test
    public void theGapBetweenPassesComesFromThePlan() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1234)),
            Collections.<String>emptyList());
        AutoImportDriver driver = new AutoImportDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals(Collections.singletonList(1234L), host.pauses);
    }

    @Test
    public void aPassHoldsTheWakeLockAndGivesItBack() throws Exception {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1)),
            Collections.<String>emptyList());
        AutoImportDriver driver = new AutoImportDriver(host);

        driver.runOnePass();

        assertEquals(1, host.wakeLocksTaken.get());
        assertEquals("the CPU must be let go of between passes, not held for the life of the service",
            1, host.wakeLocksReleased.get());
    }

    @Test
    public void aPassIsNotStartedWhileOneIsAlreadyRunning() throws Exception {
        final CountDownLatch stepStarted = new CountDownLatch(1);
        final CountDownLatch stepMayFinish = new CountDownLatch(1);

        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1)),
            Collections.<String>emptyList()) {

            @Override
            public boolean runStep(AutoImportPlan.Step step) {
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

        final AutoImportDriver driver = new AutoImportDriver(host);

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

        assertEquals("and it must not start one after the first finished either",
            1, host.stepsRun.size());
        assertEquals("only one plan is read, because only one pass ran", 1, host.plansRead.get());
    }
}
