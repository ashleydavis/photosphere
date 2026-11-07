# List S3 directories once per bucket name, show loading, ignore stale answers

## Overview

The S3 browser asks the server for a listing on every keystroke in the Bucket field. Typing `my-photos` sends a request for `m`, `my`, `my-` and so on, each of which may fail or answer after the one for the full name and whichever answer lands last is what the list shows. While a request is in flight the list is empty and the browser says "No sub-directories found here.", which is the same thing it says about an empty bucket. Failures are shown with `String(err)`, so every message starts with `Error: `. The core also answers a listing with an empty array when the named S3 secret is not in the vault, which the browser then reports as an empty bucket. This plan lists a bucket once the user stops typing, shows a loading line while a listing runs, drops any answer that is not for the latest request, shows `err.message` and makes the core refuse a listing for a missing secret. The request bookkeeping goes in a unit-tested `lib/` function.

## Issues

- `packages/user-interface/src/components/s3-browser-modal.tsx` `handleBucketChange` (around lines 63 to 72) calls `loadListing` on every change of the Bucket input.
- `loadListing` sets `entries` to whatever `platform.listS3Dirs` returns, with no check that the request is still the latest one. `handleNavigate`, `handleBreadcrumb` and `handleGoRoot` share the same race.
- The empty message (around lines 184 to 188) shows whenever `bucket && entries.length === 0 && !listError`, including while a request is in flight.
- Every `.catch` does `setListError(String(err))`.
- `listS3Dirs` in `packages-zig/photosphere-core/src/lib/databases.zig` returns `[]` when `vault.get` finds no secret by that name and `packages-zig/photosphere-core/src/test/databases.test.zig` "list-s3-dirs replies an empty array when the vault holds no secret of that name" asserts it.
- The "Select this location" button and the breadcrumb root button have no data-id.

## Steps

1. **The request bookkeeping as plain functions.** Add `packages/user-interface/src/lib/s3-listing.ts`, with a comment block at the top saying it decides what the S3 browser shows while listings come and go, so an answer to an earlier request can never replace the answer to a later one. Export:
    - `S3ListingStatus`: `"idle" | "loading" | "loaded" | "failed"`, with a comment on what each means (`idle`: no bucket to list).
    - `IS3ListingState`, with a commented field each: `latestRequestId: number` (the id of the most recent listing asked for; answers carrying any other id are dropped), `status: S3ListingStatus`, `entries: string[]`, `errorMessage: string | undefined`.
    - `initialS3Listing(): IS3ListingState`: id `0`, `idle`, no entries, no error.
    - `startS3Listing(state: IS3ListingState, requestId: number): IS3ListingState`: records `requestId` as the latest, `loading`, no entries, no error.
    - `clearS3Listing(state: IS3ListingState, requestId: number): IS3ListingState`: records `requestId` as the latest, so any answer still on its way is dropped and goes back to `idle` with no entries and no error. Used when the bucket is emptied or changed.
    - `applyS3ListingResult(state: IS3ListingState, requestId: number, entries: string[]): IS3ListingState`: returns `state` unchanged when `requestId !== state.latestRequestId`; otherwise `loaded` with the entries.
    - `applyS3ListingFailure(state: IS3ListingState, requestId: number, errorMessage: string): IS3ListingState`: unchanged for a stale id; otherwise `failed` with the message and no entries.
    Write `packages/user-interface/src/test/lib/s3-listing.test.ts` (see Unit Tests). Run `bun run test -- s3-listing` and watch it pass.

2. **The browser uses them.** In `packages/user-interface/src/components/s3-browser-modal.tsx`:
    - Replace the `entries` and `listError` states with `const [listing, setListing] = useState<IS3ListingState>(initialS3Listing());` and add `const requestCounter = useRef(0);` with a comment saying it hands out the ids `s3-listing.ts` compares and that it is a ref because the id is needed synchronously, before the state update lands.
    - Rewrite `loadListing(targetBucket, targetPrefix)` to take `const requestId = ++requestCounter.current;`, `setListing(previous => startS3Listing(previous, requestId))`, then await `platform.listS3Dirs` and `setListing(previous => applyS3ListingResult(previous, requestId, dirs))` and in its `catch` `setListing(previous => applyS3ListingFailure(previous, requestId, (err as Error).message))`. `loadListing` then never rejects, so the four `.catch(err => setListError(String(err)))` calls go; call it with `.catch(err => log.exception('S3 listing error:', err as Error))` for anything thrown outside the `try`, importing `log` from `utils`.
    - Add `const bucketDebounce = useDebounce(400);` from `../lib/use-debounce`, as `packages/user-interface/src/components/set-location-dialog.tsx` does for its search. In `handleBucketChange`, set the bucket, reset the prefix, take a new id and `setListing(previous => clearS3Listing(previous, requestId))`, then, when the new bucket is not empty, `bucketDebounce.schedule(() => loadListing(newBucket, ''))`; when it is empty, `bucketDebounce.cancel()`. Navigation (`handleNavigate`, `handleBreadcrumb`, `handleGoRoot`) lists at once, without the debounce, because each is one deliberate click.
    - Render from `listing.status`: `loading` shows a `Box` with `CircularProgress size="sm"` and `Typography` `Loading…` (`data-id="s3-browser-loading"`); `failed` shows the existing `s3-browser-error` line with `listing.errorMessage`; `loaded` with entries shows the existing list; `loaded` with none shows `No sub-directories found here.` with `data-id="s3-browser-empty"`; `idle` shows neither.
    - Give the root breadcrumb button `data-id="s3-browser-root"` and the "Select this location" button `data-id="s3-browser-select"`, unless they already have data-ids.
    `bun run compile` passes.

3. **The core refuses a listing for a missing secret.** In `packages-zig/photosphere-core/src/lib/databases.zig` `listS3Dirs`, replace `return try allocator.dupe(u8, "[]");` in the `orelse` with `return utils.errors.throwError("There is no secret named \"{s}\" in the vault, so the bucket cannot be listed.", .{s3_key});` and change the comment above the function to drop "or an empty array when the vault holds no secret of that name". In `packages-zig/photosphere-core/src/test/databases.test.zig`, rename "list-s3-dirs replies an empty array when the vault holds no secret of that name" to "list-s3-dirs with no secret of that name is an error reply" and make it `requestError` and assert that exact sentence with the key name in it, as the neighbouring tests do. Run `bun run test:zig` and watch it pass.

4. **Add pause and resume helpers for the S3 emulator.** In `apps/photosphere-smoke-tests/lib/common.sh`, beside `stop_s3_emulator`, add these two functions unless they are already there:
    - `pause_s3_emulator <state-dir>`: reads `<state-dir>/minio.pid` (written by `scripts/s3-emulator.sh` when it starts the server) and sends that one pid `kill -STOP`. Fails the test with `log_error` and `exit 1` when the file is missing or the signal cannot be sent.
    - `resume_s3_emulator <state-dir>`: sends the same pid `kill -CONT`. Never fails and returns 0, including when no server was started, so it is safe in a cleanup trap.
    Each gets a comment block saying what it is for: a stopped server accepts connections and answers none, which holds an S3 request in flight for as long as a test needs, without a timer. Both signal the recorded pid only, never a process found by name.

5. **Extend `apps/photosphere-smoke-tests/25-s3-database/test.sh`.** Add `resume_s3_emulator "$S3_STATE_DIR"` as the first line of its `cleanup`, before `cleanup_apps`. Then:
    - In pass 1, after the two `expect_listed_dir` calls: click `s3-browser-dir-0` (`alpha-dir`, which holds only `seeded.txt`, per `scripts/seed-s3-bucket.ts`) and `wait_for_value "$APP_PORT" s3-browser-empty "No sub-directories found here."`. Click `s3-browser-root` and `expect_listed_dir 1 "beta-dir"` again.
    - Add a pass between 1 and 2 for loading and for typing: open the browser with the existing steps of `open_s3_browser` up to the Cancel wait (split the bucket typing out of `open_s3_browser` into its own step so this pass can pause first), `pause_s3_emulator "$S3_STATE_DIR"`, type `no-such-bucket` into `s3-browser-bucket-input` and straight after it type `$S3_EMULATOR_BUCKET`. `wait_for_value "$APP_PORT" s3-browser-loading "Loading"`, then check `read_value "$APP_PORT" s3-browser-empty` is empty and fail the test with `log_error` when it is not. `resume_s3_emulator "$S3_STATE_DIR"`, `expect_listed_dir 0 "alpha-dir"` and check `read_value "$APP_PORT" s3-browser-error` is empty, so the half-typed name was never listed. `close_s3_browser`.
    - In pass 2, after the existing `Failed to list directories` wait, read the error with `read_value` and fail the test when it starts with `Error: `, the prefix `String(err)` added.
    - Update the header comment's list of what the test asserts.
    Run `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` and watch both pass.

6. **Run the other scenarios that open the S3 browser or list S3** and watch each pass on host and Android: `26-s3-database-lifecycle`, `27-s3-replicate` and `28-s3-failure`. Read each first: a scenario that types a bucket and then acts at once must wait for a listed entry or for `s3-browser-empty`, now that listing starts after the debounce rather than on the keystroke.

7. **Update the documentation to match the code.**
    - `docs/database-names-and-paths.md`, "How a user gives a path", "In the app": the S3 browser lists the bucket once typing stops, shows Loading while it lists and says so when the listing fails, including when the S3 secret it was given is no longer in the vault.
    - No manual test opens the S3 browser today (`grep -rln "Browse S3\|S3 browser" docs/testing/e2e` finds none), so add `docs/testing/e2e/desktop/database/browse-s3.md` and `docs/testing/e2e/mobile/s3/browse-s3.md`, in the layout of `docs/testing/e2e/desktop/database/edit-database-origin.md`, using `bun run start-minio` for the server as `docs/testing/e2e/mobile/auto-import/auto-import-new-remote.md` does. Each types a bucket into the S3 browser of the Add Database dialog, expects **Loading…** (`s3-browser-loading`) and then the directories, opens a folder with no sub-folders and expects `No sub-directories found here.` (`s3-browser-empty`) and types a bucket that does not exist and expects the error (`s3-browser-error`) to start with `Failed to list directories`. List each in its folder's `README.md` and add `- [ ]` entries under "Database" in the Desktop section and "S3" in the Mobile section of `docs/testing/e2e/CHECKLIST.md`.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`, "Adding a Database": one sentence saying Browse S3 lists the bucket once typing stops and says so when it cannot.
    - Stories: in `packages/user-interface/src/stories/modals/s3-browser-modal.stories.tsx`, keep `s3-browser-modal/open` and add `s3-browser-modal/failing`, whose mock `listS3Dirs` rejects with `new Error("Failed to list directories in my-bucket/: Access Denied")`, so typing a bucket in the story shows the error line as a user sees it. Run `bun run stories:ziggy -- --headless --no-screenshots` and watch it report no failed story.

## Unit Tests

`packages/user-interface/src/test/lib/s3-listing.test.ts`, with a description at the top saying it checks that the S3 browser shows the answer to the latest request and no other:

- A new state is `idle` with no entries and no error.
- Starting a listing is `loading` with no entries and clears an earlier error.
- The answer to the latest request is shown as `loaded` with its entries, including an empty list.
- An answer to an earlier request that arrives after a later one started is dropped: start 1, start 2, result for 1 leaves the state `loading` for 2; result for 2 then shows its entries.
- An answer to an earlier request that arrives after the later one finished is dropped and does not replace the later entries.
- A failure of the latest request is `failed` with its message and no entries; a failure of an earlier request is dropped.
- Clearing drops an answer still on its way: start 1, clear with 2, result for 1 leaves the state `idle`.

`packages-zig/photosphere-core/src/test/databases.test.zig`: "list-s3-dirs with no secret of that name is an error reply" (step 3).

No unit test for the modal: it is a React component. Step 5 covers it.

## Smoke Tests

- `apps/photosphere-smoke-tests/25-s3-database`, host and Android: a folder with no sub-folders says `No sub-directories found here.`; while the server is paused the browser says Loading and not the empty message; typing a wrong name and then the right one lists only the right one, with no error; a failed listing's message has no `Error: ` prefix.
- `26-s3-database-lifecycle`, `27-s3-replicate` and `28-s3-failure`, host and Android, still passing.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `bun run test:zig` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` exit 0.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- Decided: a 400 ms debounce on the Bucket field rather than listing on Enter or on blur. The test driver's `type` command (`doType` in `packages/user-interface/src/lib/test-driver.ts`) sets the value and fires `input` and `change` and has no key or blur command, so Enter or blur would need a new test command in the app, which is test-only scaffolding. A debounce also needs no extra action from a user on a phone keyboard. 400 ms is what `set-location-dialog.tsx` uses for its search box.
- The debounce alone does not stop a stale answer: a slow listing for one name can still finish after the listing for the next. The request id check in `s3-listing.ts` is what does and it covers clicks into folders too.
- The two `type` commands in the smoke pass usually land inside one debounce window, so only the full name is listed. When the device is slow enough that they do not, the half-typed name is listed too, its request hangs on the paused server and after the resume its failure arrives for a request that is no longer the latest and is dropped. The assertions (the right directories, no error shown) hold either way and they fail when the request id check is missing and the late answer lands last. The core's own `Error listing S3 directories` line for that request is already allowed by the scenario's `check_no_errors` pattern.
- The ids come from a ref and are compared inside functional state updates, so a check never reads an out-of-date state.
- The missing-secret change makes a listing that cannot run fail. Before, it answered with an empty list and the browser said the bucket was empty, which is the failure test 25's pass 2 was written to catch for bad credentials.
- The smoke test pauses the S3 server, by the pid the emulator script recorded, to see the loading line. A fast server would otherwise answer before the line could be read. A run in another worktree has its own server and pid and is untouched.
- `String(err)` becomes `(err as Error).message`. `platform.listS3Dirs` rejects with an `Error`, as every `messages.invoke` call does, so the message is the core's sentence (`Failed to list directories in ...` from `packages-zig/storage-zig/src/lib/cloud-storage.zig`).
