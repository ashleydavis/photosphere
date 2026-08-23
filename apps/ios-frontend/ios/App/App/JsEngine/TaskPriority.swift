import Foundation

//
// How urgent a task is, which decides the order the engine pool dispatches pending tasks in.
//
// The counterpart of TaskPriority in packages/task-queue/src/lib/types.ts, and the raw values below
// must stay identical to the string values there, because that is what crosses the Capacitor bridge.
// Keep it in step with TaskPriority in the Android TaskPriority.java.
//
enum TaskPriority: String {

    //
    // Something the user is waiting on: opening a database, reading the database list. Dispatched
    // ahead of every background task, however long those have been waiting.
    //
    case interactive

    //
    // Work that happens on its own, which is automatic import, syncing and everything they queue.
    // Dispatched only when no interactive task is waiting.
    //
    case background

    //
    // The priority a task runs at when the WebView did not ask for one and no parent task set it.
    //
    static let defaultPriority: TaskPriority = .background
}

//
// The error thrown when the bridge hands over a priority string that is not one of the two levels.
// Loud rather than silently treating a typo as background, which would hide a task that was meant to
// be interactive for the life of the app.
//
struct UnknownTaskPriorityError: Error {

    //
    // The string that was not recognised.
    //
    let wireName: String

    //
    // What to tell the caller.
    //
    var message: String {
        return "Unknown task priority \"\(wireName)\"."
    }
}

//
// Turns the bridge's string back into a priority. A nil value means the WebView did not ask for one,
// which is not an error: the pool then uses the parent's priority, or the default.
//
func taskPriority(fromWireName wireName: String?) throws -> TaskPriority? {
    guard let wireName = wireName else {
        return nil
    }
    guard let priority = TaskPriority(rawValue: wireName) else {
        throw UnknownTaskPriorityError(wireName: wireName)
    }
    return priority
}
