package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

//
// What one background automatic import pass should do, as answered by the plan-auto-import task.
//
// Nothing here is decided natively. The task reads the settings file and hands back the tasks the
// pass has to run, already built, so this is a carrier rather than a decision: the driver runs the
// steps in order and never assembles a task payload of its own. That is what keeps the format of the
// settings file, and what a pass consists of, in one tested place in TypeScript instead of in two
// native languages.
//
public final class AutoImportPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    public static final class Step {

        //
        // The task type to queue (for example "import-assets").
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
    // Whether a pass should run at all. False means automatic import is switched off, and the
    // background import stops.
    //
    public final boolean shouldRun;

    //
    // The sandbox-relative path of the database the pass imports into. Carried for the log line that
    // says what is being backed up and where.
    //
    public final String databasePath;

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
    public AutoImportPlan(boolean shouldRun, String databasePath, long pauseBetweenRunsMs, List<Step> steps) {
        this.shouldRun = shouldRun;
        this.databasePath = databasePath;
        this.pauseBetweenRunsMs = pauseBetweenRunsMs;
        this.steps = Collections.unmodifiableList(new ArrayList<>(steps));
    }
}
