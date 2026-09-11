# What this test does not cover on iOS

This test runs on Android only, and skips on iOS saying so. The gap is written down here rather than left as an absence nobody notices.

It is the same gap 57-prefetch-retries has, for the same reason, and that file explains it in full: the loop's decisions are unit tested on both platforms, and what iOS reserves to itself is running a pass while the app is not foregrounded, which only the system can start and which no automated test here can force on Xcode 14.2.

## What this test adds over 57, and where that is covered on iOS

What is new here is that the replica is encrypted, so reading the merkle tree that says whether it is partial needs the key out of the device keychain. That decision is not native code on either platform: it is the `plan-prefetch` worker task, and the encrypted case is unit tested in `packages/mobile-worker/src/test/lib/plan-prefetch.worker.test.ts` against a genuinely encrypted replica, which is the same TypeScript in the same embedded engine on iOS.

What is iOS-specific is only where the key comes from: the Keychain rather than `EncryptedSharedPreferences`. That path is covered on iOS by every encrypted-database test in the suite that runs there, because the app cannot read such a database at all without it.

So the fault this test exists for, a prefetch plan that asks whether a replica is partial without the credentials to read it, cannot be platform-specific and is covered on both.
