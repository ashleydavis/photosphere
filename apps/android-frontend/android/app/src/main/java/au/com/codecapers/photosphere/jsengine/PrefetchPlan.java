package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

//
// What one background prefetch pass should do, as answered by the plan-prefetch task.
//
// Nothing here is decided natively. The task reads the settings file, asks the platform what kind of
// connection this is, checks the database has an origin and is a partial replica, and hands back the
// task the pass has to run, already built. This is a carrier rather than a decision: the driver runs
// the steps in order and never assembles a task payload of its own. That is what keeps the settings
// format and what a pass consists of in one tested place in TypeScript instead of in two native
// languages.
//
public final class PrefetchPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    public static final class Step {

        //
        // The task type to queue (for example "prefetch-database").
        //
        public final String type;

        //
        // The task's input data as a JSON string, forwarded to the engine unchanged.
        //
        public final String dataJson;

        //
        // Constructs a step. Both fields are required and final.
        //
        public Step(String type, String dataJson) {
            this.type = type;
            this.dataJson = dataJson;
        }
    }

    //
    // Whether a prefetch should run right now.
    //
    // False never ends the loop, for the same reason it does not end the sync loop: every reason to
    // refuse can go away without the app being touched. A phone moves onto Wi-Fi, a network comes
    // back, a database gets an origin, the user switches syncing on again. What ends this loop is a
    // pass that finds nothing left to fetch, which is a different thing and is the driver's decision
    // rather than the plan's.
    //
    public final boolean shouldRun;

    //
    // The sandbox-relative path of the database the pass fills in. Carried for the log line that says
    // what is being filled in and from where. Empty when no prefetch is running.
    //
    public final String databasePath;

    //
    // Why no prefetch is running, for the log. Empty when one is.
    //
    public final String reason;

    //
    // How long to wait after this pass finishes before starting the next one, in milliseconds.
    //
    public final long pauseBetweenRunsMs;

    //
    // The tasks the pass runs, in order. Empty when shouldRun is false.
    //
    public final List<Step> steps;

    //
    // Constructs a plan. The steps are copied and held unmodifiable so the driver cannot be handed a
    // list that changes under it while a pass is running.
    //
    public PrefetchPlan(
        boolean shouldRun,
        String databasePath,
        String reason,
        long pauseBetweenRunsMs,
        List<Step> steps) {
        this.shouldRun = shouldRun;
        this.databasePath = databasePath;
        this.reason = reason;
        this.pauseBetweenRunsMs = pauseBetweenRunsMs;
        this.steps = Collections.unmodifiableList(new ArrayList<>(steps));
    }
}
