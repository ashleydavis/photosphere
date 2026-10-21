//
// Photosphere's MacOS entry point: runs the AppKit application with Photosphere's delegate.
//

import AppKit

// Starts the application. There is no storyboard or nib, so this creates the delegate itself.
@main
enum AppMain {
    // Runs until the application quits.
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
