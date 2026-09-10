# What this test does not cover on iOS

This test runs on Android only, and skips on iOS saying so. The gap is written down here rather than left as an absence nobody notices.

## What is covered on iOS

The driver that runs a background prefetch pass is the same code on both platforms (`apps/ios-frontend/ios/App/App/JsEngine/PrefetchDriver.swift`, the counterpart of `PrefetchDriver.java`), and its decisions are unit tested there (`apps/ios-frontend/ios/App/AppTests/PrefetchDriverTests.swift`, case for case with `PrefetchDriverTest.java`). That includes the decision this test exists for: a pass that fetched nothing and found nothing missing ends the loop, a pass that left files missing does not, and a failed pass does not.

Whether a pass may run at all is not native code on either platform: it is the `plan-prefetch` worker task, which is unit tested in `packages/mobile-worker/src/test/lib/plan-prefetch.worker.test.ts`, and the connection rule it applies is `computeSyncAllowed` in `packages/api`, unit tested there. The settings, the connection type, the missing origin and the database that is not a partial replica are therefore covered identically on both platforms.

What one pass actually fetches is `prefetchDatabaseHandler` in `packages/node-api`, which is the same TypeScript in the same embedded engine on both platforms and is unit tested there.

On iOS the loop also runs while the app is foregrounded, so a prefetch that happens with the app on screen is exercised by the suite whenever it runs on the simulator.

## What is not covered, and why

What iOS reserves to itself is running a pass when the app is **not** foregrounded. That happens through a `BGProcessingTask`, and the system decides when one runs: typically while the phone is charging and idle, and it may not run for a long time. There is no supported way for an automated test to make one happen except an lldb command issued against a running app (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"..."]`), and this harness has no way to issue it: the local iOS environment is fixed at macOS 12.7.6 and Xcode 14.2, and the smoke-test runner drives the simulator through `simctl` rather than through a debugger.

So the following are unverified on iOS by any automated test:

- That the background processing task for the prefetch is registered at launch and accepted by the system, including that its identifier is in `Info.plist`'s `BGTaskSchedulerPermittedIdentifiers` (a missing entry crashes the app at launch, so this one at least fails loudly and immediately on any run of the app at all).
- That its handler runs one pass and asks for the next one.
- That the expiration handler stops the pass rather than leaving it running.
- That the loop is started again, after it has finished a replica, when the app returns to the foreground.

## What would close the gap

The same thing that would close it for 50-background-sync: a way to issue an lldb command to the running simulator app from the harness, which needs a newer Xcode than this project can use. Until then the Android test is what proves the loop end to end, and the iOS unit tests are what prove the decisions it makes.
