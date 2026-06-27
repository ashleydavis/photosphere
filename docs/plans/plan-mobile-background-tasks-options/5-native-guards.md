# Step 5: Native NOT IMPLEMENTED helper, host-bridge dispatch, and path-sandbox guard

Add the native scaffolding that makes unimplemented host functions fail loudly and that sandboxes all path-taking host functions, on both platforms.

## What to do

1. Add a one-line `notImplemented(name)` helper on each platform (Swift and Java) that throws/rejects the exact message: `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`
2. Wire the host-bridge dispatch so:
   - the default/unknown-method branch throws the NOT IMPLEMENTED message including the called function name and platform, and
   - a declared-but-unfinished function throws the same message from its body.
3. Ensure the error propagates as the task's failure: `runTask` lets it reject, native catches it and sends it as the `errorMessage` in the `taskCompleted` event, and it is written to the native log (`NSLog` / `android.util.Log`) at error level.
4. Add the shared path-sandbox guard used by every path-taking host function: reject absolute paths and any path containing `..`, then resolve/normalise and verify the resolved path is still inside the storage root before any IO; otherwise throw (surfaces as the task error).

## Tests

- Native path-sandbox unit tests on both platforms: traversal vectors (`../foo`, absolute paths, encoded `..`) are rejected and a path inside the root is accepted, exercised via the shared guard.
- Native NOT IMPLEMENTED test on both platforms: an unfinished/unknown host function throws the exact NOT IMPLEMENTED message and logs it at error level.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
