package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

//
// What one background sync pass should do, as answered by the plan-sync task.
//
// Nothing here is decided natively. The task reads the settings file, asks the platform what kind of
// connection this is, applies the same rule the app's interface applies, and hands back the task the
// pass has to run, already built. This is a carrier rather than a decision: the driver runs the steps
// in order and never assembles a task payload of its own. That is what keeps the settings format and
// what a pass consists of in one tested place in TypeScript instead of in two native languages.
//
public final class SyncPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    public static final class Step {

        //
        // The task type to queue (for example "sync-database").
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
    // Whether a sync should run right now.
    //
    // False never ends the loop, unlike the import plan's equivalent, because every reason to refuse
    // a sync can go away without the app being touched: a phone moves onto Wi-Fi, a network comes
    // back, a database gets an origin, the user switches syncing on again. A loop that ended on a
    // refusal would need something to notice each of those and start it again, and a loop nobody
    // restarted is the silent kind of broken this app has been bitten by before.
    //
    public final boolean shouldRun;

    //
    // The sandbox-relative path of the database the pass syncs. Carried for the log line that says
    // what is being pushed and from where. Empty when no sync is running.
    //
    public final String databasePath;

    //
    // Why no sync is running, for the log. Empty when one is.
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
    public SyncPlan(
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
