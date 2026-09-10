# What this test does not cover on iOS

This test runs on Android only, and skips on iOS saying so. The gap is written down here rather than left as an absence nobody notices.

## What is covered on iOS

The decision itself is not native code on either platform. `plan-sync` refuses a pass while a prefetch is working, and that is unit tested in `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts`: the working case is refused and names the prefetch, and the stalled, complete, unknown and absent cases all allow syncing, which is what stops a prefetch that cannot finish from stopping a phone syncing for ever. The master switch and the connection check are asserted to win over a working prefetch, so a phone on cellular is refused for being on cellular.

The state the decision is made from comes from the prefetch driver, and both drivers are unit tested on the same cases: `apps/ios-frontend/ios/App/AppTests/PrefetchDriverTests.swift` and `apps/android-frontend/.../PrefetchDriverTest.java` each assert that a pass which fetched files and left some reports working, one that fetched nothing and left some reports stalled, one that fetched nothing with nothing missing reports complete, a failed or throwing step reports stalled rather than complete, and a refused pass leaves the state as it was.

What is only in native code is the wiring that carries that state into the task, and it is the same three lines on both platforms: the plugin reads the driver's state and puts it in the task's input data.

## What is not covered, and why

The ordering between the two loops, end to end, with the app off screen. On iOS the loops run while the app is foregrounded and otherwise through `BGProcessingTask`s the system schedules when it chooses, and the only way to make one happen is an lldb command issued against a running app (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"..."]`), which this harness has no way to issue: the local iOS environment is fixed at macOS 12.7.6 and Xcode 14.2, and the runner drives the simulator through `simctl` rather than through a debugger.

So the following are unverified on iOS by any automated test:

- That the prefetch driver's state reaches `plan-sync` at all, rather than the plugin sending a value the task does not read.
- That a background sync pass is actually refused while a prefetch is working.
- That a background sync pass runs again once the replica is filled in.

The Android test asserts all three, against the same TypeScript task both platforms ask, so a mistake in the decision would be caught there. A mistake in the iOS wiring alone would not.

## What would close the gap

The same thing that would close it for 50-background-sync and 57-prefetch-retries: a way to issue an lldb command to the running simulator app from the harness, which needs a newer Xcode than this project can use.
