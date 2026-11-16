# Root causes: the Release Windows, Linux and iOS smoke test failures at c1c947fa8

Three workflows failed on `zig-2` at commit `c1c947fa8`, each in one smoke test, each for a different reason. All three have failed the same way in every run that reached the test since the test was added (2026-11-13), so all three are constant failures.

## Release Windows: test 88 `config-file`

- **Run:** https://github.com/ashleydavis/photosphere/actions/runs/43783823603, job `cli-smoke-tests`.
- **Failing line:**

  ```
  Config file: C:/.../88-config-file-wcWDf7/config-file/config\config.toml
  [FAIL] psi version names the config file (pattern 'C:/.../config-file/config/config.toml' not found in output)
  ```

- **Root cause:** test 88 expects `psi version` to print `$PHOTOSPHERE_CONFIG_DIR/config.toml` (and `$PHOTOSPHERE_STATE_DIR/state.json`) with a `/`. Ziggy joins the directory override and the file name with the platform's separator, `\` on Windows (`packages/ziggy/config-state/src/lib/config-path.zig`), and Ziggy's own unit test expects exactly that: `/chosen/config\config.toml` on Windows. psi prints what Ziggy gives it. The test is wrong, not psi.
- **Proof:** experiment 1 (run 43789582519) ran test 88 twice on one build on one runner. Side A, as committed, failed on the line above (exit 1). Side B changed only the two expectations to accept either separator (`[\\/]`, `experiments/windows-side-b.patch`) and passed (exit 0).

## Release Linux: scenario 69 `system-theme-change`

- **Run:** https://github.com/ashleydavis/photosphere/actions/runs/43783823626, job `app-smoke-tests`.
- **Failing line:**

  ```
  [FAIL] Timed out waiting for the document's data-joy-color-scheme to be 'dark' (last value: light)
  ```

  The app's log for the scenario says `ziggy native app: could not read the system theme from the desktop portal (the settings proxy could not be made), so it is light`. Its start took 25 seconds longer than usual, which is D-Bus's timeout.
- **Root cause:** Ziggy's Linux app reads and follows the system theme only through the desktop portal's Settings interface (`org.freedesktop.portal.Settings` on the session bus). The runner has no session bus set (`DBUS_SESSION_BUS_ADDRESS` unset) and no portal serving Settings, so the app takes light and never hears of a change. The scenario changes the theme with `gsettings`, which reaches the app only through such a portal. Its guard, `photosphere_platform_changes_appearance`, only checks that `gsettings` can read the setting.
- **Proof:** experiment 3 (run 43791645023) ran scenario 69 twice on one build on one runner with the repository's code unchanged.
  - Side A, as the runner has it, failed as in CI.
  - Side B ran the scenario inside `dbus-run-session` with `xdg-desktop-portal`, its GNOME and GTK backends, and a `portals.conf` naming the Settings backend. Before the scenario, the portal read the colour scheme as `(<uint32 0>,)`, followed a `gsettings set ... prefer-dark` to `(<uint32 1>,)` and a reset back to `(<uint32 0>,)`. Then `[PASS] The page followed a change of the system's theme while the app ran` and `PASSED: 69-system-theme-change`.
  - Experiments 1 and 2 show that a portal without a Settings backend is not enough: there the portal answered `No such interface "org.freedesktop.portal.Settings"` and the scenario failed the same way.

## Release iOS: scenario 68 `system-theme`

- **Run:** https://github.com/ashleydavis/photosphere/actions/runs/43783823685, job `app-smoke-tests`.
- **Failing lines:**

  ```
  68-system-theme/test.sh: line 11: photosphere_platform_system_theme: command not found
  68-system-theme/test.sh: line 11: fail: command not found
  [FAIL] Timed out waiting for the document's data-joy-color-scheme to be '' (last value: light)
  ```

- **Root cause:** scenario 68 calls `photosphere_platform_system_theme`, which every other platform library defines but the iOS simulator's library, `lib/ios.sh`, does not. The call fails, `expected` is empty, and the scenario waits for the page's theme to become `''`.
- **Proof:** experiment 1b (run 43790635983) ran scenario 68 twice on one build on one simulator. Side A, as committed, failed with the lines above (exit 1). Side B added only a `photosphere_platform_system_theme` to `lib/ios.sh` that reads `xcrun simctl ui <udid> appearance` (`experiments/ios-side-b.patch`) and passed: `PASSED: 68-system-theme` (exit 0).

## Found on the way, not the cause of these failures

- No library defines `fail`, which scenarios 68 and 69 call when the theme cannot be read. Bash reports `fail: command not found` and the scenario carries on instead of stopping there.
- On a branch that cannot restore `zig-2`'s Zig build cache, the iOS `app-build` rebuilt every third-party library for the simulator and stopped because ImageMagick's generated simulator headers were not there (experiment 1, run 43789582583). The `build-*` actions generate those files only when they build the library themselves. Experiment 1b generated them in `app-build` so the experiment could run. I did not find why the build decides to rebuild when that cache is missing.

## Files

- `ci-logs/windows-cli-smoke-tests-133028622599.log`, `ci-logs/linux-app-smoke-tests-133028522253.log`, `ci-logs/ios-app-smoke-tests-133030309296.log`: the original failing jobs.
- `ci-logs/linux-scenario-69-run-43783823626/`: scenario 69's own logs from the original Linux run (`app.log` with the portal error and the 25-second gap, `scenario-run.log`, `system-appearance.txt`).
- `ci-logs/experiment1-windows-cli-smoke-tests-133049750794.log` and `ci-logs/experiment1-windows-side-a-test-88/test-run.log`: the Windows experiment, both sides, and side A's full test log.
- `ci-logs/experiment1-linux-app-smoke-tests-*.log`, `ci-logs/experiment2-linux-app-smoke-tests-*.log`: the Linux side B attempts whose portal had no Settings.
- `ci-logs/experiment3-linux-app-smoke-tests-133052488586.log`: the Linux proof, both sides, with the portal's debug output.
- `ci-logs/experiment1-ios-app-build-133045130483.log`: the iOS build that stopped on the missing simulator headers.
- `ci-logs/experiment1b-ios-app-smoke-tests-133053906701.log`: the iOS proof, both sides.
- `experiments/windows-side-b.patch`, `experiments/ios-side-b.patch`: the only changes between side A and side B for Windows and iOS.
- `.github/workflows/release-windows.yml`, `release-linux.yml`, `release-ios.yml` on this branch: the experiment workflows, cut down to the builds and the one smoke job each. Release Linux and Release iOS can be started by hand on this branch to run the proofs again.

The commit log of branch `root-cause-windows-linux-smoke` records each experiment before it ran and its result after.
