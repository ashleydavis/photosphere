# Root cause: Release iOS scenario 8-share-database timed out waiting for "Database opened"

## The failure

- Run: https://github.com/ashleydavis/photosphere/actions/runs/43827893187 (Release iOS, commit 05de13c95 on zig-2), job
  app-smoke-tests (133168513203).
- Failing line, in `apps/photosphere-smoke-tests/8-share-database/test.sh`:

  ```
  [INFO] Found: Database entry added (line 43)
  [INFO] Waiting for log pattern: Databases page loaded (after line 43)
  [INFO] Found: Databases page loaded (line 48)
  [INFO] Waiting for log pattern: Database opened (after line 48)
  [FAIL] Timed out waiting for log pattern: Database opened
  ```

  app.log, in the order the app wrote it:

  ```
  47.427Z [EVENT] [Worker 4] Database entry added
  47.430Z [INFO] [Frontend] Opening database: test-db
  47.439Z [EVENT] [Worker 2] Database opened: test-db
  47.467Z [EVENT] [Frontend] Databases page loaded
  47.554Z [EVENT] [Frontend] Databases page loaded
  47.558Z [INFO] [Frontend] test-navigate: navigating to /databases
  ```

- It is intermittent. The same commit passed scenario 8 in run 43818856777. Of the 14 failed Release iOS runs back to 9 November, it
  failed only in 43827893187. In experiments 1 and 2 it passed 20 of 20 runs as committed.

## Root cause

The test assumes the add dialog's list re-render logs `Databases page loaded` before the open the dialog starts next logs
`Database opened`. Nothing guarantees that order:

- `handleAdd` (`add-database-modal.tsx`) awaits `addDatabase`, which awaits `refreshDbs()` and so `setDbs()`, then awaits
  `openDatabase`.
- The databases page logs `Databases page loaded` from a `useEffect` on `[databases, secrets]` (`databases-page.tsx:100`). It runs
  only after React commits the `setDbs` render.
- The open's `Database opened` comes about 10 ms after `Opening database:`.

Which line comes first is a race between React running that effect and the open's round trip.

`wait_for_log` only matches lines after its previous match. When the effect runs after `Database opened`, the test's wait for
`Databases page loaded` after its navigate matches a line that comes after `Database opened`. Its next wait, for
`Database opened`, can then never match, and it times out after 120 s.

This is a bug in the test, not in the app: the app does both things. The test's waits depend on an order the app does not promise.

## The proof (experiment 2)

There was one app build, with one change, in `addDatabase` (`packages/user-interface/src/context/app-context.tsx`). For an entry
whose name starts `Root cause delay`, it re-reads the list 500 ms later instead of before returning. That puts the list's re-render
after `Database opened`. The entry's name is the switch, so both sides ran on the same build.

- **Side B**, scenario 8 as committed (entry "My Test DB", no delay): 10 of 10 passed, every one with `Databases page loaded` at
  line 47 before `Database opened` at line 48.
- **Side A**, the only change being the entry's name typed as "Root cause delay DB"
  (`experiments/experiment2-side-a-test.sh`): 5 of 5 failed exactly as run 43827893187 did:

  ```
  Found: Database entry added (line 43)
  Found: Databases page loaded (line 54)
  Waiting for log pattern: Database opened (after line 54)
  [FAIL] Timed out waiting for log pattern: Database opened
  ```

  with app.log in the failed run's order:

  ```
  10.834Z [EVENT] [Worker 4] Database entry added
  10.835Z [INFO] [Frontend] Opening database: test-db
  10.860Z [EVENT] [Worker 1] Database opened: test-db
  10.970Z [EVENT] [Frontend] Databases page loaded
  10.973Z [INFO] [Frontend] test-navigate: navigating to /databases
  ```

Run: https://github.com/ashleydavis/photosphere/actions/runs/43858139511, job 133273790712.

Experiment 1 (run 43845593218) first tried to force the order from the test. That cannot work, because the order is the app's.
It also showed that moving the wait for `Database opened` up is not a fix on its own: the last wait for `Databases page loaded`
then has no line left to match, and it failed 10 of 10. The branch's commit log has the details.

## Files

- `ci-logs/fail-43827893187-app-smoke-tests-133168513203.log`: the failed job's full log.
- `ci-logs/pass-43818856777-app-smoke-tests-133139982830.log`: the passing job on the same commit, with the opposite order (line 47
  `Databases page loaded`, line 48 `Database opened`).
- `ci-logs/experiment1-43845593218-app-smoke-tests-133233920079.log`: experiment 1. Baseline 10 of 10 passed, the test-side hold
  5 of 5 passed and the reordered waits 10 of 10 failed on the last wait.
- `ci-logs/experiment2-43858139511-app-smoke-tests-133273790712.log`: experiment 2, the proof.
- `extract-*.txt`: the wait, result and event lines of each log above.
- `experiments/side-a-test.sh` and `experiments/side-b-test.sh`: experiment 1's test variants.
- `experiments/experiment2-side-a-test.sh`: experiment 2's side A test.
- `.github/workflows/release-ios.yml` on this branch: the cut-down workflow that runs the experiments. The app change is in
  `packages/user-interface/src/context/app-context.tsx`.
