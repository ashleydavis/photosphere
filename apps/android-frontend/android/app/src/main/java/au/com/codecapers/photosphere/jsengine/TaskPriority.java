package au.com.codecapers.photosphere.jsengine;

//
// How urgent a task is, which decides the order the engine pool dispatches pending tasks in.
//
// The counterpart of TaskPriority in packages/task-queue/src/lib/types.ts, and the wire names below
// must stay identical to the string values there, because that is what crosses the Capacitor bridge.
// Keep it in step with TaskPriority in the iOS TaskPriority.swift.
//
public enum TaskPriority {

    //
    // Something the user is waiting on: opening a database, reading the database list. Dispatched
    // ahead of every background task, however long those have been waiting.
    //
    INTERACTIVE("interactive"),

    //
    // Work that happens on its own, which is automatic import, syncing and everything they queue.
    // Dispatched only when no interactive task is waiting.
    //
    BACKGROUND("background");

    //
    // The priority a task runs at when the WebView did not ask for one and no parent task set it.
    //
    public static final TaskPriority DEFAULT = BACKGROUND;

    //
    // The string this priority crosses the bridge as.
    //
    private final String wireName;

    //
    // Constructs a priority with the string it crosses the bridge as.
    //
    TaskPriority(String wireName) {
        this.wireName = wireName;
    }

    //
    // The string this priority crosses the bridge as.
    //
    public String getWireName() {
        return wireName;
    }

    //
    // Turns the bridge's string back into a priority. A null or absent value means the WebView did
    // not ask for one, which is not an error: the pool then uses the parent's priority, or the
    // default. An unrecognised value IS an error and throws, because silently treating a typo as
    // background would hide a task that was meant to be interactive for the life of the app.
    //
    public static TaskPriority fromWireName(String wireName) {
        if (wireName == null) {
            return null;
        }
        for (TaskPriority priority : values()) {
            if (priority.wireName.equals(wireName)) {
                return priority;
            }
        }
        throw new IllegalArgumentException("Unknown task priority \"" + wireName + "\".");
    }
}
