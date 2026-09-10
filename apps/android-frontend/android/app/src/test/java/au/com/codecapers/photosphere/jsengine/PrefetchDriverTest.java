package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

//
// Plain-JVM unit tests for the background prefetch's decisions.
//
// The driver holds every decision the loop makes and holds no Android at all, which is what lets
// these run on the JVM: the service supplies the engine pool, the clock, the wake lock and logcat
// through the Host interface, and a recording double supplies them here.
//
// The decision that matters most is when to stop. This loop is the only thing that repairs a replica
// whose prefetch failed, so a loop that stops for the wrong reason leaves the replica unfinished with
// nothing left to notice, which is the failure the whole loop exists to remove.
//
public final class PrefetchDriverTest {

    //
    // A plan with one prefetch step, which is what an ordinary pass looks like.
    //
    private static PrefetchPlan runningPlan(long pauseMs) {
        return new PrefetchPlan(
            true,
            "photosphere-default",
            "",
            pauseMs,
            Collections.singletonList(new PrefetchPlan.Step("prefetch-database", "{}")));
    }

    //
    // A plan that refuses a pass, for one of the reasons that can go away on its own.
    //
    private static PrefetchPlan refusedPlan(long pauseMs) {
        return new PrefetchPlan(
            false,
            "",
            "the connection is \"cellular\" and syncing is not allowed on it",
            pauseMs,
            new ArrayList<PrefetchPlan.Step>());
    }

    //
    // A host that answers with the plans it is given, records what it was asked to do, and never
    // really waits.
    //
    private static class RecordingHost implements PrefetchDriver.Host {

        //
        // The plans handed out, one per pass, the last one repeating once they run out.
        //
        private final List<PrefetchPlan> plans;

        //
        // What running a step reports.
        //
        private final PrefetchDriver.StepResult stepResult;

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
        // True once the driver reported that the replica is complete.
        //
        volatile boolean stoppedReported = false;

        //
        // Set to end the loop from inside a pause, standing in for the service being stopped.
        //
        volatile PrefetchDriver driverToStopWhilePaused = null;

        //
        // Constructs a host answering with the given plans and step result.
        //
        RecordingHost(List<PrefetchPlan> plans, PrefetchDriver.StepResult stepResult) {
            this.plans = plans;
            this.stepResult = stepResult;
        }

        @Override
        public PrefetchPlan readPlan() {
            int index = plansRead.getAndIncrement();
            return plans.get(Math.min(index, plans.size() - 1));
        }

        @Override
        public PrefetchDriver.StepResult runStep(PrefetchPlan.Step step) {
            stepsRun.add(step.type);
            return stepResult;
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
    public void aPassThatFetchedNothingAndFoundNothingMissingEndsTheLoop() {
        // The replica is complete. Walking every object at the origin again every gap is thousands of
        // listings and thousands of local existence checks on a real library, so the loop stops and is
        // started again when a database is opened.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1)),
            new PrefetchDriver.StepResult(true, 0, 0));
        PrefetchDriver driver = new PrefetchDriver(host);

        driver.runLoop();

        assertTrue("the loop should report itself finished", host.stoppedReported);
        assertEquals("the pass still ran", Collections.singletonList("prefetch-database"), host.stepsRun);
        assertTrue("nothing is waited for once the loop is over", host.pauses.isEmpty());
    }

    @Test
    public void aPassThatLeftFilesMissingKeepsTheLoopGoing() {
        // Something was fetched and something is left: the prefetch is working through the replica and
        // the next pass carries on.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(9)),
            new PrefetchDriver.StepResult(true, 3, 5));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a replica with files still missing is not finished", host.stoppedReported);
        assertEquals("the next pass is scheduled", Collections.singletonList(9L), host.pauses);
    }

    @Test
    public void aPassThatFetchedFilesAndLeftNoneKeepsTheLoopGoing() {
        // It did work and found nothing left, which is not the same as finding nothing to do: the walk
        // it just finished may have raced with files arriving at the origin, so one more pass confirms
        // it and that pass is the one that stops.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(11)),
            new PrefetchDriver.StepResult(true, 4, 0));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a pass that fetched something is not the pass that ends the loop",
            host.stoppedReported);
        assertEquals(Collections.singletonList(11L), host.pauses);
    }

    @Test
    public void aFailedStepKeepsTheLoopGoing() {
        // This is the whole reason the loop exists: a prefetch that failed used to be never tried
        // again, and the replica it left unfinished could not be repaired by a sync.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(7)),
            new PrefetchDriver.StepResult(false, 0, 0));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a failed pass must never be read as a complete replica", host.stoppedReported);
        assertEquals("the next pass is still scheduled after a failure",
            Collections.singletonList(7L), host.pauses);
    }

    @Test
    public void aStepThatThrowsKeepsTheLoopGoing() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(4)),
            new PrefetchDriver.StepResult(true, 0, 0)) {

            @Override
            public PrefetchDriver.StepResult runStep(PrefetchPlan.Step step) {
                stepsRun.add(step.type);
                throw new IllegalStateException("the engine went away");
            }
        };
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a step that threw must not be read as a complete replica", host.stoppedReported);
        assertEquals(Collections.singletonList(4L), host.pauses);
    }

    @Test
    public void aRefusedPlanKeepsTheLoopGoing() {
        // Every reason a plan refuses (syncing switched off, a cellular connection, no database, no
        // origin, a database that is not partial) can stop being true without the app being touched,
        // so a refusal is not the end of the loop.
        RecordingHost host = new RecordingHost(
            Collections.singletonList(refusedPlan(13)),
            new PrefetchDriver.StepResult(true, 0, 0));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a refusal is not a finished replica", host.stoppedReported);
        assertTrue("no step runs when the plan refused", host.stepsRun.isEmpty());
        assertEquals("and the loop waits and asks again", Collections.singletonList(13L), host.pauses);
    }

    @Test
    public void aPlanThatCannotBeReadDoesNotEndTheLoop() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(3)),
            new PrefetchDriver.StepResult(true, 0, 0)) {

            @Override
            public PrefetchPlan readPlan() {
                plansRead.incrementAndGet();
                throw new IllegalStateException("the engine is not there");
            }
        };
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertFalse("a failed plan read must not be taken as a complete replica", host.stoppedReported);
        assertEquals("the loop keeps going and asks again", 1, host.pauses.size());
    }

    @Test
    public void stoppingBetweenPassesEndsTheLoop() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(5)),
            new PrefetchDriver.StepResult(true, 1, 1));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals("exactly one pass runs before the stop", 1, host.plansRead.get());
        assertEquals("and it waits once before finding out it has been stopped", 1, host.pauses.size());
        assertTrue("the driver reports itself stopped", driver.isStopped());
        assertFalse("being stopped is not the same as the replica being complete", host.stoppedReported);
    }

    @Test
    public void aStoppedDriverRunsNoFurtherPasses() throws Exception {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1)),
            new PrefetchDriver.StepResult(true, 1, 1));
        PrefetchDriver driver = new PrefetchDriver(host);

        driver.stop();
        driver.runLoop();

        assertEquals("a stopped driver asks for no plan at all", 0, host.plansRead.get());
        assertTrue("and runs no step", host.stepsRun.isEmpty());
    }

    @Test
    public void theGapBetweenPassesComesFromThePlan() {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1234)),
            new PrefetchDriver.StepResult(true, 1, 1));
        PrefetchDriver driver = new PrefetchDriver(host);
        host.driverToStopWhilePaused = driver;

        driver.runLoop();

        assertEquals(Collections.singletonList(1234L), host.pauses);
    }

    @Test
    public void aPassHoldsTheWakeLockAndGivesItBack() throws Exception {
        RecordingHost host = new RecordingHost(
            Collections.singletonList(runningPlan(1)),
            new PrefetchDriver.StepResult(true, 1, 1));
        PrefetchDriver driver = new PrefetchDriver(host);

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
            new PrefetchDriver.StepResult(true, 1, 1)) {

            @Override
            public PrefetchDriver.StepResult runStep(PrefetchPlan.Step step) {
                stepsRun.add(step.type);
                stepStarted.countDown();
                try {
                    stepMayFinish.await(5, TimeUnit.SECONDS);
                }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
                return new PrefetchDriver.StepResult(true, 1, 1);
            }
        };

        final PrefetchDriver driver = new PrefetchDriver(host);

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
