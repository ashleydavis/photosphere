# What this test does not cover on iOS

This test runs on Android only, and skips on iOS saying so. The gap is written down here rather than left as an absence nobody notices.

## What is covered on iOS

The driver that runs an automatic import pass is the same code on both platforms (`apps/ios-frontend/ios/App/App/JsEngine/AutoImportDriver.swift`, the counterpart of `AutoImportDriver.java`), and on iOS it runs a loop while the app is foregrounded. Test 47 exercises that loop on the simulator whenever the suite runs there: switching automatic import on, the database being created, and photos being taken in are all the same path.

## What is not covered, and why

What iOS reserves to itself is running a pass when the app is **not** foregrounded. That happens through a `BGProcessingTask`, and the system decides when one runs: typically while the phone is charging and idle, and it may not run for a long time. There is no supported way for an automated test to make one happen except an lldb command issued against a running app (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"..."]`), and this harness has no way to issue it: the local iOS environment is fixed at macOS 12.7.6 and Xcode 14.2, and the smoke-test runner drives the simulator through `simctl` rather than through a debugger.

So the following are unverified on iOS by any automated test:

- That the background processing task is registered at launch and accepted by the system.
- That its handler runs one pass and asks for the next one.
- That the expiration handler stops the pass rather than leaving it running.
- That switching automatic import off withdraws the pending request.

## What this means for the product

Android keeps importing with the app off screen and the screen off, in a foreground service, and test 49 proves it. iOS catches up when the system allows, and the settings card says so rather than implying continuous backup (see `backgroundImportDescription` in the mobile platform provider). That difference is the platform rather than a design choice, and it is not something a future change to this test can close.
