# What this test does not cover on iOS

This test runs on Android only, and skips on iOS saying so. The gap is written down here rather than left as an absence nobody notices.

## What is covered on iOS

The driver that runs a background sync pass is the same code on both platforms (`apps/ios-frontend/ios/App/App/JsEngine/SyncDriver.swift`, the counterpart of `SyncDriver.java`), and its decisions are unit tested there (`apps/ios-frontend/ios/App/AppTests/SyncDriverTests.swift`, case for case with `SyncDriverTest.java`). On iOS the loop runs while the app is foregrounded, so a sync that happens with the app on screen is exercised by the suite whenever it runs on the simulator.

The rule that decides whether a sync may run at all is not native code on either platform: it is `computeSyncAllowed` in `packages/api`, reached through the `plan-sync` worker task, and both are unit tested. The two syncing settings and the connection type they are judged against are therefore covered identically on both platforms, including the cellular case no device test can reach.

## What is not covered, and why

What iOS reserves to itself is running a pass when the app is **not** foregrounded. That happens through a `BGProcessingTask`, and the system decides when one runs: typically while the phone is charging and idle, and it may not run for a long time. There is no supported way for an automated test to make one happen except an lldb command issued against a running app (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"..."]`), and this harness has no way to issue it: the local iOS environment is fixed at macOS 12.7.6 and Xcode 14.2, and the smoke-test runner drives the simulator through `simctl` rather than through a debugger.

So the following are unverified on iOS by any automated test:

- That the background processing task for syncing is registered at launch and accepted by the system.
- That its handler runs one pass and asks for the next one.
- That the expiration handler stops the pass rather than leaving it running.
- That switching automatic import off withdraws the pending request.
- That a photo imported while the app is off screen reaches the origin without the app being opened.

There is a second reason the end-to-end half cannot run on the simulator, and it is the same one test 49 records: the iOS simulator has no supported way to remove a seeded photo from its library, so a test that seeds one poisons every run after it.

## What this means for the product

Android keeps syncing with the app off screen and the screen off, in the same foreground service that runs the import, and this test proves it. iOS catches up when the system allows. That difference is the platform rather than a design choice, and it is not something a future change to this test can close. [Syncing](../../../../docs/syncing.md) says so in the same words the settings card does.
