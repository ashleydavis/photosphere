import Foundation

//
// Where the answer to the next photo library delete request is staged, mirroring Android's
// MediaDeleteBroker.
//
// The Photos framework presents its own confirmation for deleting assets the app did not create, and
// that confirmation cannot be tapped by an automated test. Staging the answer leaves everything above
// it under test: choosing which photos are confirmed present in the database, batching them into one
// request, and handling both answers.
//
// The answer is consumed by one request, so a test that stages "deleted" once does not silently
// answer every later request as well. Nothing stages an answer in production, so the real request is
// issued.
//
enum MediaDeleteStaging {

    //
    // Guards the staged answer and the record of what it answered, which are written from the main
    // thread and read from an engine thread.
    //
    private static let lock = NSLock()

    //
    // The answer staged for the next request, or nil when none is staged.
    //
    private static var stagedOutcome: Bool?

    //
    // How many items each staged request was asked to delete, most recent last.
    //
    private static var stagedRequestSizes: [Int] = []

    //
    // Stages the answer to the next delete request.
    //
    static func stage(deleted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        stagedRequestSizes.removeAll()
        stagedOutcome = deleted
    }

    //
    // Reads and clears the staged answer, or returns nil when none is staged.
    //
    static func consume() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        let outcome = stagedOutcome
        stagedOutcome = nil
        return outcome
    }

    //
    // Records how many items a staged request was asked to delete.
    //
    static func record(requestSize: Int) {
        lock.lock()
        defer { lock.unlock() }
        stagedRequestSizes.append(requestSize)
    }

    //
    // The sizes of the requests a staged answer answered, most recent last.
    //
    static func requestSizes() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return stagedRequestSizes
    }

    //
    // Whether an answer is staged for the next request.
    //
    static func hasStagedOutcome() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stagedOutcome != nil
    }

    //
    // Forgets any staged answer and the record of what it answered.
    //
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        stagedOutcome = nil
        stagedRequestSizes.removeAll()
    }
}
