//
// The hold the background work takes while a pass is running, so the app keeps running when it leaves the screen. It is given back
// between passes: a phone has no use for a process kept running while nothing is being done.
//
// Counted, because the passes of the background loops overlap. Each takes a hold for its own pass and gives it back afterwards, and the
// system is free to suspend the app when the last hold goes. iOS has no wake lock. What keeps a process running in the background is a
// background task assertion, which the system ends after a limited time, and the app is suspended then.
//

import Foundation
import UIKit

// The count of holds, and the background task assertion that stands for them.
final class BackgroundWakeHold {
    // How many holds are taken. Read and written on the main thread only.
    private var holds = 0

    // The assertion held while any hold is taken. Read and written on the main thread only.
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    // Takes one hold (awake true) or gives one back (awake false). Applied on the main thread, in the order the calls were made.
    func hold(_ awake: Bool) {
        DispatchQueue.main.async {
            self.apply(awake)
        }
    }

    // Runs on the main thread.
    private func apply(_ awake: Bool) {
        if awake {
            holds += 1
            if assertion == .invalid {
                assertion = UIApplication.shared.beginBackgroundTask(withName: "photosphere-background-pass") { [weak self] in
                    self?.endAssertion()
                }
            }
            return
        }
        if holds == 0 {
            BackgroundWakeHold.report("a hold was given back that was never taken")
            return
        }
        holds -= 1
        if holds == 0 {
            endAssertion()
        }
    }

    // Gives the assertion back to the system.
    private func endAssertion() {
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
    }

    // Writes a problem to standard error and carries on.
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("photosphere shell: \(message)\n".utf8))
    }
}
