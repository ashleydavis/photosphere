# Destructive command audit

## Headline numbers

185 shell scripts were audited. 84 of them contain a destructive command in their own text, a further 93 reach one only through a shared helper library or a program they invoke, and 8 contain and reach none. 224 destructive occurrences are listed in the inventory table below. **28 occurrences are rated dangerous**, spread over 12 scripts. That is a bad number for a repository whose test suite runs on a developer's own machine: 13 of the 28 take a path or a network interface name straight from a command-line option or an environment variable and hand it to a recursive delete or an ownership change, with no check that the target is anything the script created, a further 7 are `pkill` on a pattern broad enough to match a process the user started, and one deletes every object in a named S3 bucket. Three of them are one mistyped argument away from deleting a real directory: `apps/cli/smoke-tests.sh --tmp-dir <dir> reset`, `apps/cli/smoke-tests-encrypted.sh --tmp-dir <dir> reset`, and `bun run stories -- --screenshots <dir>`.

This document fixes nothing. It is an inventory.

## Scope and method

### What was counted as a shell script

The inventory came from commands, not from memory:

- `git ls-files '*.sh'` produced 183 tracked shell scripts.
- `git status --porcelain --untracked-files=all` was run against the main working copy and reported no untracked or modified shell scripts, so nothing was added on that account.
- Every other tracked file was checked for a `#!` first line. Two shell scripts have no `.sh` extension and were added: `.githooks/pre-commit` and `apps/android-frontend/android/gradlew`.

That gives 185 files. Two classification decisions are recorded rather than silently applied:

- `apps/android-frontend/android/gradlew` is vendored third-party code (the Gradle wrapper). It is in the report with its findings, which are none, and no change to it is proposed.
- `apps/desktop/scripts/setup-electron-builder.ps1` is PowerShell, not shell, so it is not in the 185. It is covered in its own short section below, because it can destroy state the same way. `apps/android-frontend/android/gradlew.bat` is the vendored Windows batch counterpart of `gradlew` and is covered in the same section.
- `scripts/clear-s3-bucket.js` has a `#!/usr/bin/env node` shebang, so it is not a shell script and is not in the 185. It is named in the findings because a shell script invokes it and it deletes every object in a bucket.

### What was counted as destructive

Six categories, greped across the whole inventory and then confirmed by reading each script end to end:

- **A, git repository state.** `git init`, `add`, `commit`, `config`, `checkout`, `reset`, `restore`, `rm`, `stash`, `branch`, `merge`, `rebase`, `push`, `tag`, `clean`, `worktree remove`, `filter-branch`. Read-only git is not a finding. Only three scripts in the repository run git at all (`scripts/install-hooks.sh`, `.githooks/pre-commit`, `tools/what-changed/smoke-tests.sh`) and only one of them mutates repository state.
- **B, recursive or forced deletion.** Any `rm` whose flags include `r`, `R` or `f`.
- **C, other deletion, overwrite or truncation of existing state.** Plain `rm`, `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd`, `sed -i`, `perl -pi`, `mv` onto a path that may exist, `cp` over an existing file, and `>` redirection that clobbers an existing file. Judgement was applied to the `>` case, as the plan required: writing a fresh log or a fresh config into a temporary directory the script itself created is not listed; overwriting a file that is part of the repository, of the user's environment, or of a shared directory such as `/tmp` is listed. `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd` and `sed -i` have zero hits anywhere in the repository.
- **D, process destruction.** `kill`, `pkill`, `killall` and the helpers that wrap them. Killing a process the script itself started is low risk and is listed against the helper rather than repeated for every caller. A `pkill` matching a name pattern is listed as its own occurrence.
- **E, destruction outside the local filesystem.** Deletion on a connected device or emulator (`adb shell rm`, `adb ... run-as ... rm`, `adb shell pm clear`, `simctl keychain reset`), host network state (`ip link del`, `iptables -D`, `sysctl -w`), object storage deletion, OS keychain deletion, and the CLI's own `hash-cache clear`.
- **F, recursive permission or ownership change.** `chmod -R` and `chown -R` have zero hits. `chown`/`chmod` on a path the script did not create is listed instead, because that is the form this repository actually uses (the chrome-sandbox SUID fix).

### What the ratings mean

- **Safe.** The target is a literal, or a variable whose value is built only from the script's own location or from `mktemp`, it is provably inside a directory the script created, and it cannot be reached with the variable unset or empty.
- **Unproven.** Probably fine in practice, but the guarantee cannot be established by reading. The usual cause here is an environment variable that has a sensible default but that the caller can point anywhere.
- **Dangerous.** The target can be empty, unset, or outside the script's own scratch area on some reachable path; or the command mutates git repository state; or it deletes state the user did not ask to lose.

Destructive is not the same as wrong. Most of the `rm -rf` in this repository is a smoke test clearing its own scratch directory, which is expected behaviour and is listed anyway. The classification (is it destructive) is kept separate from the rating (is it safe).

### What was out of scope

Deletion performed inside TypeScript or JavaScript reached from a shell script was not audited beyond naming the immediate callee. Three such callees are named in the findings (`scripts/clear-s3-bucket.js`, the `psi hash-cache clear` command, the `psi secrets remove` command) and are marked indirect. A full audit of deletion in the TypeScript sources is separate work and has not been done.

The audit was performed by reading. No script under audit was executed, and no script under audit was edited.

### What the inventory table lists

The table lists every occurrence found by the category greps for A, B, D (pattern-matching kills only), E and F, plus the category C occurrences judgement kept: deletion, overwrite or truncation of state that already exists outside a scratch directory the script itself created. Two things are deliberately not repeated per row, because doing so would bury the findings that matter under a hundred identical entries:

- `kill` of a pid the script recorded itself, or of its own job list. These are listed once against the helper that performs them, under Shared helpers, and summarised under Safe.
- `>` redirection of a log, a port file or a seeded config into a temporary directory the script created moments earlier.

Neither omission hides an occurrence rated above safe. Both are stated here so that a "none" in the table is read as "no destructive command in the categories above", not as "this script writes nothing".

### Reconciliation

The set of paths in the inventory table below was compared mechanically against the inventory the commands above produced. The two sets are equal: 185 paths, no path in one and not the other, no duplicates. Every row has either at least one listed command or the word "none"; no cell is blank.

## Findings by rating

### Dangerous

**1. `run-cloud-storage-tests.sh:80`, every object in a named S3 bucket.**
Command: `node scripts/clear-s3-bucket.js "$TEST_S3_BUCKET"`. Target expression: `$TEST_S3_BUCKET`, an environment variable the caller sets, checked only for being non-empty (line 33). Reachable path: exporting `TEST_S3_BUCKET` to a production bucket name and answering `y` twice. The two interactive confirmations (lines 61 and 68) print the bucket name, so a human has two chances to notice, but nothing in the script constrains the name to a test bucket. Blast radius: every object in that bucket, permanently.

**2. `apps/cli/smoke-tests-encrypted.sh:237`, a caller-named directory.**
Command: `rm -rf "$TEST_TMP_DIR"`, guarded only by `[ -d "$TEST_TMP_DIR" ]`. Target expression: `$TEST_TMP_DIR`, set at line 25 from the environment with the default `./test/tmp-encrypted`, and overridden verbatim by `-t <dir>` (line 1452) or `--tmp-dir=<dir>` (line 1456). Reachable path: `apps/cli/smoke-tests-encrypted.sh --tmp-dir <a-real-directory> reset` deletes that directory. Blast radius: any directory the caller names.

**3. `apps/cli/smoke-tests-encrypted.sh:280`, a caller-named directory, one level down.**
Command: `rm -rf "$dir"` in `prepare_test_dir`, where `dir` is `$TEST_TMP_DIR/<test-name>`. Same root as finding 2, so the same argument reaches it, one path component deeper. Blast radius: a subdirectory of any directory the caller names.

**4. `apps/cli/smoke-tests.sh:281, 378, 630, 920`, a caller-named directory.**
Command: `rm -rf "$TEST_TMP_DIR"` at four sites (setup, reset, run-all, and `to <n>`). Target expression: `$TEST_TMP_DIR`, set at line 57 from the environment with the default `$_CLI_ABS_DIR/test/tmp`, and overridden verbatim by `-t <dir>` (line 862) or `--tmp-dir=<dir>` (line 867). Reachable path: `apps/cli/smoke-tests.sh --tmp-dir <a-real-directory> reset`. Blast radius: any directory the caller names. Note that line 525 in the same file writes `rm -rf "${TEST_TMP_DIR:?}/${dir_name}"`, which is the one guarded deletion in the repository; the four sites above have no such guard.

**5. `apps/cli/smoke-tests.sh:388`, a sibling of the database directory.**
Command: `rm -rf "$replica_dir"` where `replica_dir="$TEST_DB_DIR-replica"`. The target is built by string concatenation onto `$TEST_DB_DIR`, which is `$TEST_TMP_DIR/shared/test-db` and follows `--tmp-dir`. It is not a child of the test directory but a sibling formed by appending a suffix, so a `TEST_DB_DIR` ending in a real path deletes `<that path>-replica`. Blast radius: a sibling of any directory the caller names.

**6. `scripts/story-player.sh:493`, a caller-named directory.**
Command: `rm -rf "$SCREENSHOTS_DIR"`. Target expression: `$SCREENSHOTS_DIR`, taken verbatim from `--screenshots <dir>` (line 74) with the default `$REPO_DIR/stories-screenshots/<platform>`. Reachable path: `bun run stories -- --screenshots <a-real-directory>` deletes that directory. The `--screenshots <dir>` option is documented in CLAUDE.md as a supported way to run the story player. Blast radius: any directory the caller names.

**7. `apps/desktop/screenshots/capture-ux.sh:24`, an environment-named directory.**
Command: `rm -rf "$TMP_DIR" "$OUT_DIR"`. `OUT_DIR` is `${OUT_DIR:-$REPO_DIR/ux-review/screenshots}` (line 20), so an `OUT_DIR` already exported in the caller's environment is deleted recursively. Reachable path: `OUT_DIR=<a-real-directory> bun run ux:review` (or any wrapper that exports `OUT_DIR`). Blast radius: any directory named in that variable. The script runs under `set -uo pipefail` with no `-e`.

**8. `apps/smoke-tests/lib/runner.sh:534`, the test directory's parent.**
Command: `rm -rf "$dir/$RUN_TMP_NAME"` where `RUN_TMP_NAME="${PHOTOSPHERE_TEST_TMP:-tmp}"` (line 208) and `dir` is the directory of the test being run. `PHOTOSPHERE_TEST_TMP` is an environment variable used unvalidated as a path suffix. Reachable path: `PHOTOSPHERE_TEST_TMP=.. bun run test:and` makes the command `rm -rf <test-dir>/..`, deleting `apps/smoke-tests/tests` and every test in it; `PHOTOSPHERE_TEST_TMP=../../..` reaches further. `apps/smoke-tests/run.sh:31` normally sets it to `tmp/run-$$`, but it honours an existing value. Blast radius: the repository working tree.

**9. `apps/cli/smoke-tests-lan-share.sh:186, 187, 189, 204, 604`, any matching process on the machine.**
Commands: `pkill -f "bun run start.*--yes"`, `pkill -f "bun run.*udp-listen"`, `pkill -9 -f "bun run start.*--yes"`, `pkill -f "bun run.*receive --yes"` (twice). These match on the full command line of every process on the machine, not on processes this script started. Reachable path: a developer running `bun run start -- ... --yes` in another terminal while this suite runs has that process killed, and line 604 fires at suite start before any test. Blast radius: the user's own long-running `bun` processes, including an import in progress.

**10. `cli-desktop-lan-share-smoke-tests.sh:59, 60`, any matching process on the machine.**
Commands: `pkill -f "bun run.*secrets (send|receive)"` and `pkill -f "bun run.*dbs (send|receive)"`, in the `EXIT` trap. Same reasoning and same blast radius as finding 9.

**11. `apps/android-frontend/scripts/emulator.sh:313`, a host network interface.**
Command: `ip link del "$netcard"`, running as root, iterating `$PSPHERE_TAPS`. `PSPHERE_TAPS` is passed in by `cmd_down`/`cmd_pool_down` from literal prefixes, but the privileged subcommand is reachable directly: `sudo PSPHERE_TAPS=eth0 apps/android-frontend/scripts/emulator.sh __bridge-down` deletes `eth0`. Nothing checks that the named interface is one the script created. Blast radius: the machine's real network interface. (`set -u` means an unset `PSPHERE_TAPS` aborts before this line, so the empty case is covered; the wrong-value case is not.)

**12. `apps/smoke-tests/lib/android.sh:436`, the app's entire data directory on the attached device.**
Command: `adb shell pm clear "$APP_ID"`. `adb` is invoked without `-s`, so it targets `$ANDROID_SERIAL` or whatever single device is attached. `android_ready_devices` (line 70) accepts any device adb reports, not only emulators. Reachable path: a real phone with the app installed plugged in while `bun run test:and` runs. Blast radius: all Photosphere data on that phone, including its keychain entries.

**13. `apps/smoke-tests/lib/android.sh:487`, the app's files directory on the attached device.**
Command: `adb shell run-as "$APP_ID" rm -rf files`. Same targeting as finding 12, same blast radius, reached from `android_cleanup`, which `apps/smoke-tests/run.sh:44` calls for every device slot at the end of every run.

**14. `apps/cli/smoke-tests.sh:642, 748, 930, 1000`, the machine's shared hash cache.**
Command: `$(get_cli_command) hash-cache clear`. The CLI resolves the local hash cache to `getProcessTmpDir()/photosphere` (`apps/cli/src/cmd/hash-cache-tools.ts:19-21`), which is the system temp directory and is not scoped by `PHOTOSPHERE_CONFIG_DIR` or by `TEST_TMP_DIR`. Reachable path: running any of the CLI smoke-test entry points. Blast radius: the hash cache that the user's own `psi` runs share, so real imports lose their cached hashes and re-hash from scratch. Indirect (the deletion is inside the CLI).

**15. `apps/desktop/scripts/test-post-install.sh:82, 86`, ownership of a caller-named file.**
Commands: `sudo chown root:root "${CHROME_SANDBOX}"` and `sudo chmod 4755 "${CHROME_SANDBOX}"`, where `CHROME_SANDBOX="${UNPACKED_DIR}/chrome-sandbox"` and `UNPACKED_DIR` is `$1` (line 46). Reachable path: passing any directory that happens to contain a file called `chrome-sandbox`. Blast radius: that file becomes root-owned and setuid, which the invoking user can no longer undo without sudo.

**16. `scripts/install-hooks.sh:31`, git repository state.**
Command: `git config core.hooksPath .githooks`. This is a category A mutation of the repository's own configuration and is classified as destructive because it overwrites whatever `core.hooksPath` was set to (the script prints the previous value at line 28 but does not preserve it). It is deliberate: it is the mechanism that installs the hooks, and the file is frozen by project rule. The classification is not softened; the rating records what the command does, not whether somebody wanted it.

### Unproven

**`apps/cli/diff-dirs.sh:157`, word splitting in a trap.**
Command: `trap "rm -rf $TMPDIR" EXIT`. The trap body is in double quotes, so `$TMPDIR` is expanded when the trap is installed, one line after `TMPDIR=$(mktemp -d)` at line 156. The expansion is unquoted inside the trap string, so a temporary path containing whitespace or a glob character splits into several arguments and `rm -rf` receives all of them. Cannot be proven safe by reading, because `mktemp` honours the caller's `TMPDIR`. The script also reassigns `TMPDIR` itself, which changes where every later `mktemp` in the process writes.

**`apps/cli/demo-news.sh:29, 44` and `apps/desktop/demo-news.sh:38`, trap on a possibly-empty variable.**
Command: `trap 'rm -rf "$DEMO_CONFIG"' EXIT INT TERM` and `rm -rf "$DEMO_CONFIG"` in `reset_state`. `DEMO_CONFIG=$(mktemp -d)` is assigned on the line before the trap is installed, so the trap can never fire with the variable unset. Neither script uses `set -e`, so a failing `mktemp` leaves `DEMO_CONFIG` empty and the command becomes `rm -rf ""`, which errors harmlessly rather than deleting anything. Unproven rather than safe because the safety rests on `rm` rejecting an empty argument, not on anything the script does.

**Every `rm -rf` whose target is derived from `TEST_TMP_DIR` in the CLI smoke tests.**
`apps/cli/smoke-tests/lib/common.sh:16` and `apps/cli/smoke-tests-key-chain/lib/common.sh:16` set `TEST_TMP_DIR="${ISOLATED_TEST_TMP_DIR:-${TEST_TMP_DIR:-./test/tmp}}"` and export it, so it can never be empty, and `get_test_dir` (line 28) appends a test number. Every deletion in the numbered tests therefore targets `<TEST_TMP_DIR>/<number>/<literal-name>` or `<TEST_TMP_DIR>/<literal-name>`, never a bare variable. They are unproven, not safe, because `TEST_TMP_DIR` and `ISOLATED_TEST_TMP_DIR` are environment variables set outside the script, so the directory being deleted is not provably one the script created. Affected: `apps/cli/smoke-tests/29..43`, `45`, `49..64`, `apps/cli/smoke-tests-key-chain/58..63`, `apps/cli/smoke-tests/lib/functions.sh:14, 186, 200, 415, 448, 478, 512, 528, 979, 1039`.

**`apps/cli/smoke-tests/lib/functions.sh:528`, a sibling formed by suffix.**
Command: `rm -rf "$replica_dir"` where `replica_dir="$TEST_DB_DIR-replica"`. Same suffix-concatenation shape as dangerous finding 5, but reached only with `TEST_DB_DIR` under `TEST_TMP_DIR`, so it is rated unproven rather than dangerous.

**`apps/cli/smoke-tests-lan-share.sh:169, 426, 526` and `apps/cli/sync-smoke-test.sh:246, 307` and `apps/cli/write-lock-smoke-test.sh:262, 264`.**
Recursive deletions of directories built from `TEST_TMP_DIR` or from literal `./test/tmp/...` paths relative to the current directory. `sync-smoke-test.sh` and `write-lock-smoke-test.sh` use relative literals (`./test/tmp/sync-test-db` and friends) with no `cd` to a known directory first, so the target depends on the caller's working directory.

**`apps/android-frontend/scripts/run-android.sh:200, 202, 204` and `apps/smoke-tests/lib/android.sh:378, 380, 385, 454`.**
`adb shell rm -rf` on paths built from an argument (`$FIXTURE_DB`, `$rel_dest`, `$rel`). The paths are interpreted on the device, not locally. `run-android.sh` validates that `test/dbs/<name>` exists before using the name, and `seed_fixture` runs only when the name is non-empty, so the empty case is covered; the wrong-device case is not, which is the same targeting problem as dangerous findings 12 and 13.

**`apps/smoke-tests/lib/ios.sh:179, 226, 247, 287` and `:228`.**
`rm -rf` inside the simulator's app container, each guarded by a non-empty check on the container path returned by `simctl get_app_container`, and `xcrun simctl keychain "${IOS_SIMULATOR_UDID:-booted}" reset`, which resets the whole simulator keychain rather than only this app's entries. Unproven because `IOS_SIMULATOR_UDID` defaults to `booted`, meaning whichever simulator happens to be running.

**`apps/cli/smoke-tests-key-chain/58..63/test.sh`, real OS keychain entries.**
Each test runs `psi secrets remove --name <name> --yes` with `PHOTOSPHERE_VAULT_TYPE=keychain`, against the machine's real keychain. The names are literals but generic: `keychain-test-secret`, `view-secret`, `edit-secret`, `renamed-secret`, `keep-secret`, `delete-secret`, `list-multi-secret-a/b/c`. A real keychain entry of the same name under the Photosphere service is deleted. Indirect (the deletion is inside the CLI).

**`apps/android-frontend/scripts/emulator.sh:276, 278, 340`, host kernel setting.**
`sysctl -q -w net.ipv4.ip_forward=1` turns the host into a router and `down` restores the saved value. Unproven because the restore only happens if `down` runs; a machine where `up` succeeded and `down` never ran is left forwarding.

**`apps/android-frontend/scripts/emulator.sh:427, 450`, the user's AVD directory.**
`cat > "$dir/config.ini"` and `> "$home/$name.ini"` where `home` is `${ANDROID_AVD_HOME:-$HOME/.android/avd}`. `create_base_avd` is only called with the literal `psphere-base`, so it writes a new AVD rather than overwriting an existing one, but it writes into the user's own Android configuration directory rather than a scratch area.

**`apps/desktop/scripts/deb-post-install.sh:63, 65, 86, 88` and `apps/desktop/scripts/fix-sandbox.sh:46, 49`.**
`chown root:root` and `chmod 4755` on a `chrome-sandbox` binary. `deb-post-install.sh` searches `/opt` and `/usr` with `find` (line 78) and requires a sibling `photosphere` binary before acting, which is a real guard; `fix-sandbox.sh` derives the path from its own location. Both change ownership of a file the script did not create, as root.

**`apps/smoke-tests/android-lock.sh:122`, an environment-named lock file.**
`rm -f "$LOCK_FILE"` where `LOCK_FILE="${PHOTOSPHERE_ANDROID_LOCK_FILE:-/tmp/photosphere-test-and.lock}"`. Single file, `-f` only, and the removal is refused while a run holds the lock, but the path comes from the environment.

**`apps/smoke-tests/runner.test.sh:271, 330`, a glob in the shared /tmp.**
`rm -f /tmp/photosphere-android-device-fakedev-*.lock`. The prefix is specific, but the files are in the world-writable `/tmp` and were not necessarily created by this run.

**`test/test-cli-commands.sh:37, 48`, fixed-name files in the shared /tmp.**
`> /tmp/summary_<db>.log` and `> /tmp/verify_<db>.log` clobber predictable paths in `/tmp`. A pre-existing symlink at either path is followed.

**`docs/testing/e2e/desktop/news/setup-news-feed.sh:10`, a fixed path in the shared /tmp.**
`cat > "$NEWS_FILE"` where `NEWS_FILE="/tmp/photosphere-news.yaml"`. Same reasoning as the previous entry.

**`scripts/s3-emulator.sh:190`, a caller-named state directory.**
`rm -rf "$stateDir/data" "$stateDir/env"` where `stateDir` is the script's second argument. The literal `/data` and `/env` suffixes contain the damage to two named children, but the parent is arbitrary. Reached from `apps/cli/smoke-tests/65-s3-database/test.sh`, `apps/desktop/smoke-tests/25-s3-database/test.sh` and `apps/smoke-tests/tests/40-s3-database/test.sh`, all of which pass a path under their own tmp directory.

**`scripts/update-mobile-media-tools.sh:81, 138, 151`, in-place edits of tracked repository files.**
`perl -pi -e` rewrites `apps/ios-frontend/ios/build-imagemagick.sh` and `apps/android-frontend/android/app/build.gradle` in place, and `cp`/`cp -R` overwrite the vendored `.so` files and the ImageMagick headers. Deliberate: that is what the script is for. Unproven because `--android-so-dir` and `--android-headers-dir` take arbitrary source directories whose contents are copied over repository files.

**Trap-ordering: `$APP_PORT` referenced before it is assigned.**
`apps/desktop/screenshots/capture-ux.sh:27`, `apps/desktop/smoke-tests/3-open-database/test.sh:14`, `4-import-photos/test.sh:15`, `18-move-file/test.sh:15`, `19-download-single-asset/test.sh:34`, `20-download-multiple-assets/test.sh:33` and every `apps/smoke-tests/tests/*/test.sh` install `trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT`, and `scripts/story-player.sh:488` installs `trap cleanup EXIT` where `cleanup` calls `stop_app "$APP_PORT"` at line 473. All of them do so before `start_app` assigns `APP_PORT` (`apps/desktop/smoke-tests/lib/common.sh:182`, `apps/smoke-tests/lib/common.sh:367`). The trap body is single-quoted, so the expansion happens when the trap fires. If the script exits before `start_app` returns, the trap runs with `APP_PORT` unset. Nothing destructive follows from that here (`stop_app` posts to a URL and reads a pid file), but it is the exact placement the plan flags: a trap whose target is not assigned on every path that reaches it.

### Safe

The remaining occurrences are rated safe and are not itemised individually here; each appears in the inventory table with its file and line. They fall into four shapes:

- A literal path with no variable at all (`/run/psphere-emulator-dnsmasq.pid`, `/tmp/psphere-emulator-dnsmasq.log`, `br-psphere`, `/data/local/tmp/50-assets`).
- A path built from `$(mktemp -d)` assigned before the trap that deletes it (`apps/smoke-tests/lib/runner.sh:634`, `apps/smoke-tests/run.sh:156`, `apps/smoke-tests/runner.test.sh:21`, `apps/smoke-tests/android-lock.test.sh:16`, `apps/smoke-tests/timeout.test.sh:20`, `tools/what-changed/smoke-tests.sh:36`, `scripts/test-everything-parallel.sh:120`).
- A path built from `$(dirname "${BASH_SOURCE[0]}")` or from `find` output rooted at the script's own directory (`apps/cli/hash-cache-smoke-test.sh:77`, `apps/desktop/smoke-tests.sh:120` and `:180`, `cli-desktop-lan-share-smoke-tests.sh:289, 345, 410, 472, 541`, `scripts/story-player.sh:463`, `scripts/fetch-mobile-media-tools.sh:85, 99, 121`, `apps/ios-frontend/ios/build-imagemagick.sh:49`).
- A `kill` of a pid the script itself recorded, or of its own job list (`apps/desktop/smoke-tests/lib/common.sh:218-229`, `apps/smoke-tests/lib/common.sh:669`, `apps/cli/smoke-tests-lan-share.sh:61-67`, `apps/cli/sync-smoke-test.sh:414-433`, `apps/cli/write-lock-smoke-test.sh:456-475`, `scripts/story-player.sh:432-457`, `scripts/test-everything-parallel.sh:99-116`, `scripts/s3-emulator.sh:248-252`).

## Shared helpers

One destructive line in a sourced library applies to every caller. These are the six that matter.

**`apps/cli/smoke-tests/lib/functions.sh`**, deletes at lines 14, 186, 200, 415, 430, 448, 478, 512, 528, 979, 988, 1039, and overwrites an asset file at line 999. All targets are under `TEST_TMP_DIR`. Sourced by 26 scripts: `apps/cli/smoke-tests/01-create-database` through `26-repair-damaged` (every numbered test that uses the shared fixtures).

**`apps/cli/smoke-tests/lib/common.sh`**, `rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.toml"` at line 796 and `cat > .../databases.json` at line 797, plus `cat > "$file_path"` at line 769 and `chmod 600` at line 776. It also defines `TEST_TMP_DIR` (line 16) and `get_test_dir` (line 28), which is where every caller's deletion target comes from. Sourced by 65 scripts (every `apps/cli/smoke-tests/*/test.sh`).

**`apps/cli/smoke-tests-key-chain/lib/common.sh`**, the same shape at lines 777, 778, 761, 768. Sourced by 6 scripts (`apps/cli/smoke-tests-key-chain/58..63/test.sh`).

**`apps/desktop/smoke-tests/lib/common.sh`**, `kill_app_tree` (lines 218-229) walks the process tree with `pgrep -P` and sends `SIGTERM` then `SIGKILL`; `rm -f "$tmp_dir/test-control.port"` at line 146. Only descendants of a pid the helper itself started are killed. Sourced by 28 scripts: the 26 `apps/desktop/smoke-tests/*/test.sh` plus `apps/desktop/screenshots/capture-ux.sh` plus `scripts/story-player.sh`, and indirectly by `cli-desktop-lan-share-smoke-tests.sh`.

**`apps/smoke-tests/lib/android.sh`**, the on-device deletions: `adb shell rm -rf` (378, 385, 418, 488), `adb shell run-as ... rm -rf` (380, 454, 487) and `adb shell pm clear` (436). Reached by every mobile smoke test through `apps/smoke-tests/lib/common.sh`, which sources it at line 117 when `PLATFORM=android`; that is 40 scripts under `apps/smoke-tests/`, plus `scripts/story-player.sh`.

**`apps/smoke-tests/lib/ios.sh`**, the simulator-container deletions at lines 179, 226, 247, 287 and the keychain reset at 228. Same reach as `android.sh`, sourced at `apps/smoke-tests/lib/common.sh:118` when `PLATFORM=ios`.

**`apps/smoke-tests/lib/runner.sh`**, `rm -rf "$dir/$RUN_TMP_NAME"` at line 534 (dangerous finding 8), plus `rm -f` on its own registry files (56, 81) and `rm -rf "$work_dir"` (634). Sourced by `apps/smoke-tests/run.sh` and `apps/smoke-tests/runner.test.sh`.

## PowerShell and Windows batch

`apps/desktop/scripts/setup-electron-builder.ps1` and `apps/android-frontend/android/gradlew.bat` are not shell scripts and are outside the 185, but they can destroy state the same way, so both were read in full.

`gradlew.bat` (92 lines) is the vendored Gradle wrapper for Windows. It contains no `del`, `erase`, `rd`, `rmdir` or `Remove-Item`. None.

`setup-electron-builder.ps1` (202 lines) does delete and overwrite:

- C 135 and C 170: `Remove-Item -Recurse -Force $tempExtractDir`, where `$tempExtractDir` is `Join-Path $env:TEMP "winCodeSign-extract"` (line 133). Literal name under the user's temp directory. Rated safe.
- C 166: `Remove-Item -Recurse -Force $darwinPath`, where `$darwinPath` is `Join-Path $targetDir "darwin"` and `$targetDir` is `$env:LOCALAPPDATA\electron-builder\Cache\winCodeSign\winCodeSign-2.6.0`. This deletes a folder inside the user's own electron-builder cache, not a scratch area the script created. Rated unproven.
- C 199: `Remove-Item $tempArchive -Force` on `Join-Path $env:TEMP "winCodeSign-2.6.0.7z"`. Rated safe.
- C 153 and C 159: `Move-Item ... -Destination $targetDir -Force`. `-Force` overwrites whatever is already at the destination. Rated safe, because line 17 returns early when `$targetDir` already exists.

## Full script inventory

Every script in the repository, one row each, in path order. Categories are A (git state), B (recursive or forced deletion), C (other deletion, overwrite or truncation), D (process destruction), E (destruction outside the local filesystem), F (permission or ownership change). "none directly" means the script contains no destructive command in its own text but reaches one through a helper named in the row; see Shared helpers above.

| Script | Destructive commands |
| :-- | :-- |
| `apps/android-frontend/android/gradlew` | none |
| `apps/android-frontend/scripts/android-env.sh` | none |
| `apps/android-frontend/scripts/android-gradle.sh` | none |
| `apps/android-frontend/scripts/emulator-config.sh` | none |
| `apps/android-frontend/scripts/emulator.sh` | B 235: `rm -f "$DNSMASQ_PID_FILE"`<br>B 244: `rm -f "$DNSMASQ_LOG_FILE"`<br>F 260: `chmod 0644 "$DNSMASQ_LOG_FILE" 2>/dev/null \|\| true`<br>E 278: `sysctl -q -w net.ipv4.ip_forward=1`<br>E 313: `ip link del "$netcard"`<br>B 328: `rm -f "$DNSMASQ_PID_FILE"`<br>D 334: `pkill -f "dnsmasq.*--interface=$BRIDGE_NAME" 2>/dev/null \|\| true`<br>E 340: `sysctl -q -w net.ipv4.ip_forward="$(cat "$IP_FORWARD_STATE_FILE")"`<br>B 342: `rm -f "$IP_FORWARD_STATE_FILE"`<br>E 351: `iptables -D FORWARD -i "$BRIDGE_NAME" -o "$uplink" -j ACCEPT 2>/dev/null \|\| true`<br>E 352: `iptables -D FORWARD -i "$uplink" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \|\| true`<br>E 356: `ip link del "$BRIDGE_NAME"` |
| `apps/android-frontend/scripts/run-android.sh` | E 200: `"$ADB" -s "$target" shell rm -rf "$tmp_remote" >/dev/null 2>&1 \|\| true`<br>E 202: `"$ADB" -s "$target" shell run-as "$APP_ID" rm -rf "files/$FIXTURE_DB"`<br>E 204: `"$ADB" -s "$target" shell rm -rf "$tmp_remote" >/dev/null 2>&1 \|\| true`<br>E 241: `"$ADB" -s "$target" shell rm -f "/data/local/tmp/$DATABASES_CONFIG" >/dev/null 2>&1 \|\| true`<br>B 242: `rm -f "$tmp_local"` |
| `apps/cli/check-tools.sh` | none |
| `apps/cli/demo-news.sh` | B 29: `trap 'rm -rf "$DEMO_CONFIG"' EXIT INT TERM`<br>B 44: `rm -rf "$DEMO_CONFIG"` |
| `apps/cli/diff-dirs.sh` | B 157: `trap "rm -rf $TMPDIR" EXIT` |
| `apps/cli/hash-cache-smoke-test.sh` | B 77: `rm -rf "$TEST_ROOT"` |
| `apps/cli/keychain-smoke-tests.sh` | none directly; runs each smoke-tests-key-chain/*/test.sh, which delete their own scratch directories and remove keychain entries |
| `apps/cli/smoke-tests/01-create-database/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/02-view-media/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/03-add-png/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/04-add-jpg/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/05-add-mp4/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/06-add-same/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/07-add-multiple/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/08-add-same-multiple/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/09-add-duplicate/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/10-summary/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/11-list/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/12-export/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/13-verify/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/14-verify-full/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/15-detect-deleted/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/16-detect-modified/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/17-replicate/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/18-verify-replica/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/19-replicate-second/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/20-compare/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/21-compare-changes/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/22-replicate-changes/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/23-no-overwrite/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/24-repair-ok/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/25-remove/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/26-repair-damaged/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/27-v2-readonly/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/28-v2-write-fail/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/29-v2-upgrade/test.sh` | B 24: `rm -rf "$temp_v2_dir"`<br>B 51: `rm -rf "$temp_v2_dir"` |
| `apps/cli/smoke-tests/30-v3-upgrade/test.sh` | B 24: `rm -rf "$temp_v3_dir"`<br>B 51: `rm -rf "$temp_v3_dir"` |
| `apps/cli/smoke-tests/31-v4-upgrade/test.sh` | B 25: `rm -rf "$temp_v4_dir"`<br>B 52: `rm -rf "$temp_v4_dir"` |
| `apps/cli/smoke-tests/32-v5-upgrade/test.sh` | B 22: `rm -rf "$temp_v5_dir"`<br>B 43: `rm -rf "$temp_v5_dir"` |
| `apps/cli/smoke-tests/33-v6-upgrade-no-effect/test.sh` | B 22: `rm -rf "$temp_v6_dir"`<br>B 43: `rm -rf "$temp_v6_dir"` |
| `apps/cli/smoke-tests/34-v6-add-file/test.sh` | B 24: `rm -rf "$temp_v6_dir"`<br>B 76: `rm -rf "$temp_v6_dir"` |
| `apps/cli/smoke-tests/35-sync-original-to-copy/test.sh` | B 26: `rm -rf "$original_dir"`<br>B 32: `rm -rf "$copy_dir"`<br>B 123: `rm -rf "$original_dir"`<br>B 124: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/36-sync-copy-to-original/test.sh` | B 29: `rm -rf "$original_dir"`<br>B 35: `rm -rf "$copy_dir"`<br>B 135: `rm -rf "$original_dir"`<br>B 136: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/37-sync-edit-field/test.sh` | B 30: `rm -rf "$original_dir"`<br>B 36: `rm -rf "$copy_dir"`<br>B 197: `rm -rf "$original_dir"`<br>B 198: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/38-sync-edit-field-reverse/test.sh` | B 30: `rm -rf "$original_dir"`<br>B 36: `rm -rf "$copy_dir"`<br>B 197: `rm -rf "$original_dir"`<br>B 198: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/39-sync-delete-asset/test.sh` | B 24: `rm -rf "$original_dir"`<br>B 30: `rm -rf "$copy_dir"`<br>B 183: `rm -rf "$original_dir"`<br>B 184: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/40-sync-delete-asset-reverse/test.sh` | B 24: `rm -rf "$original_dir"`<br>B 30: `rm -rf "$copy_dir"`<br>B 183: `rm -rf "$original_dir"`<br>B 184: `rm -rf "$copy_dir"` |
| `apps/cli/smoke-tests/41-replicate-deleted-asset/test.sh` | B 24: `rm -rf "$source_dir"`<br>B 56: `rm -rf "$replica_dir"`<br>B 121: `rm -rf "$source_dir"`<br>B 122: `rm -rf "$replica_dir"` |
| `apps/cli/smoke-tests/42-replicate-unrelated-fail/test.sh` | B 23: `rm -rf "$first_db_dir"`<br>B 24: `rm -rf "$second_db_dir"` |
| `apps/cli/smoke-tests/43-replicate-partial/test.sh` | B 108: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/44-vault-list-shared/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests/45-dbs-list-empty/test.sh` | B 13: `rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.json"` |
| `apps/cli/smoke-tests/46-dbs-add-and-list/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary, seed_databases_config |
| `apps/cli/smoke-tests/47-dbs-view/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary, seed_databases_config |
| `apps/cli/smoke-tests/48-dbs-remove/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary, seed_databases_config |
| `apps/cli/smoke-tests/49-dbs-resolve-by-name/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/50-dbs-resolve-by-path/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/51-dbs-no-match-fallback/test.sh` | B 15: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/52-plaintext-vault-list-empty/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/53-plaintext-vault-add/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/54-plaintext-vault-view/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/55-plaintext-vault-edit/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/56-plaintext-vault-delete/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/57-secrets-import/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/58-dbs-edit/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/59-dbs-add-cli/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/60-dbs-add-duplicate/test.sh` | B 15: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/61-secrets-add-duplicate/test.sh` | B 15: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/62-dbs-clear/test.sh` | B 15: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/63-secrets-clear/test.sh` | B 15: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/64-config-timestamps/test.sh` | B 88: `rm -rf "$db_dir"`<br>B 106: `rm -rf "$source_dir" "$replica_dir"`<br>B 135: `rm -rf "$repair_db_dir" "$repair_source_dir"`<br>B 150: `rm "$file_to_delete"`<br>B 170: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests/65-s3-database/test.sh` | none directly; reaches a destructive helper: cleanup_and_show_summary |
| `apps/cli/smoke-tests-encrypted.sh` | B 237: `rm -rf "$TEST_TMP_DIR"`<br>B 280: `rm -rf "$dir"`<br>B 1200: `rm -rf "$db2_dir"` |
| `apps/cli/smoke-tests-key-chain/58-keychain-vault-list-empty/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/59-keychain-vault-add/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/60-keychain-vault-view/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/61-keychain-vault-edit/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/62-keychain-vault-delete/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/63-keychain-vault-list-multiple/test.sh` | B 16: `rm -rf "$test_dir"` |
| `apps/cli/smoke-tests-key-chain/lib/common.sh` | F 768: `chmod 600 "$file_path"`<br>B 777: `rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.toml"` |
| `apps/cli/smoke-tests-lan-share.sh` | F 115: `chmod 600 "$file_path"`<br>B 169: `rm -rf "$SENDER_VAULT_DIR" "$SENDER_CONFIG_DIR" "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"`<br>D 186: `pkill -f "bun run start.*--yes" 2>/dev/null \|\| true`<br>D 187: `pkill -f "bun run.*udp-listen" 2>/dev/null \|\| true`<br>D 189: `pkill -9 -f "bun run start.*--yes" 2>/dev/null \|\| true`<br>D 204: `pkill -f "bun run.*receive --yes" 2>/dev/null \|\| true`<br>F 238: `chmod 600 "${SENDER_VAULT_DIR}/encsndr1.json"`<br>B 426: `rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"`<br>B 526: `rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"`<br>D 604: `pkill -f "bun run.*receive --yes" 2>/dev/null \|\| true` |
| `apps/cli/smoke-tests/lib/common.sh` | F 776: `chmod 600 "$file_path"`<br>B 796: `rm -f "${PHOTOSPHERE_CONFIG_DIR}/databases.toml"` |
| `apps/cli/smoke-tests/lib/functions.sh` | B 14: `rm -rf "$TEST_DB_DIR"`<br>B 186: `rm -rf "$db_dir"`<br>B 200: `rm -rf "$db_dir"`<br>B 415: `rm -rf "$test_copy_dir"`<br>B 430: `rm "$file_to_delete"`<br>B 448: `rm -rf "$test_copy_dir"`<br>B 478: `rm -rf "$test_copy_dir"`<br>B 512: `rm -rf "$test_copy_dir"`<br>B 528: `rm -rf "$replica_dir"`<br>B 979: `rm -rf "$damaged_dir"`<br>B 988: `rm "$file_to_delete"`<br>B 1039: `rm -rf "$damaged_dir"` |
| `apps/cli/smoke-tests.sh` | B 281: `rm -rf "$TEST_TMP_DIR"`<br>B 369: `rm -f "$UUID_COUNTER_FILE"`<br>B 378: `rm -rf "$TEST_TMP_DIR"`<br>B 388: `rm -rf "$replica_dir"`<br>C 524: `mv "$log_file" "$log_file.signal-death" 2>/dev/null \|\| true`<br>B 525: `rm -rf "${TEST_TMP_DIR:?}/${dir_name}"`<br>B 630: `rm -rf "$TEST_TMP_DIR"`<br>B 637: `rm -f "$UUID_COUNTER_FILE"`<br>E 642: `invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" \|\| {`<br>E 748: `invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" \|\| {`<br>B 920: `rm -rf "$TEST_TMP_DIR"`<br>B 926: `rm -f "$UUID_COUNTER_FILE"`<br>E 930: `invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" \|\| {`<br>E 1000: `invoke_command "Clear local cache" "$(get_cli_command) hash-cache clear" \|\| {` |
| `apps/cli/sync-smoke-test.sh` | B 246: `rm -rf "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"`<br>B 307: `rm -rf "$replica_dir"` |
| `apps/cli/test-add-multiple.sh` | B 13: `rm -rf "$TEST_DB_DIR"` |
| `apps/cli/write-lock-smoke-test.sh` | B 245: `rm -f "$temp_file"`<br>B 262: `rm -rf "$TEST_DB_DIR" "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"`<br>B 264: `rm -rf "$TEST_FILES_DIR" "$PROCESS_OUTPUT_DIR"`<br>B 377: `rm -f "$add_stdout_file"`<br>B 381: `rm -f "$add_stderr_file"`<br>B 527: `rm -f "$verify_output_file"`<br>B 530: `rm -f "$verify_output_file"` |
| `apps/desktop/demo-news.sh` | B 38: `trap 'rm -rf "$DEMO_CONFIG"' EXIT INT TERM` |
| `apps/desktop/screenshots/capture-ux.sh` | B 24: `rm -rf "$TMP_DIR" "$OUT_DIR"` |
| `apps/desktop/scripts/deb-post-install.sh` | F 63: `chown root:root "${SANDBOX_PATH}"`<br>F 65: `chmod 4755 "${SANDBOX_PATH}"`<br>F 86: `chown root:root "${SANDBOX_PATH}"`<br>F 88: `chmod 4755 "${SANDBOX_PATH}"` |
| `apps/desktop/scripts/fix-sandbox.sh` | F 46: `sudo chown root:root "${CHROME_SANDBOX}"`<br>F 49: `sudo chmod 4755 "${CHROME_SANDBOX}"` |
| `apps/desktop/scripts/test-post-install.sh` | F 82: `sudo chown root:root "${CHROME_SANDBOX}"`<br>F 86: `sudo chmod 4755 "${CHROME_SANDBOX}"` |
| `apps/desktop/smoke-tests/10-view-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/11-edit-encryption-key/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/12-edit-api-key/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/13-edit-s3-credentials/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/14-rename-secret/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/15-duplicate-name/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/16-remove-recent-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/17-news-notifications/test.sh` | B 84: `rm -f "$TMP_DIR/.log-cursor"`<br>B 122: `rm -f "$TMP_DIR/.log-cursor"` |
| `apps/desktop/smoke-tests/17-replicate-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/18-move-file/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/desktop/smoke-tests/19-download-single-asset/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/desktop/smoke-tests/1-load-fixture/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/20-download-multiple-assets/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/desktop/smoke-tests/22-edit-database-origin/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/23-developer-screen/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/24-sync-settings/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/25-s3-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/2-create-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/3-open-database/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/desktop/smoke-tests/4-import-photos/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/desktop/smoke-tests/5-add-secret/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/6-add-database-entry/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/7-share-secret/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/8-share-database/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/9-view-secret/test.sh` | none directly; reaches a destructive helper: kill_app_tree, stop_app |
| `apps/desktop/smoke-tests/lib/common.sh` | B 146: `rm -f "$tmp_dir/test-control.port"` |
| `apps/desktop/smoke-tests.sh` | B 120: `rm -rf "$dir/tmp"`<br>B 180: `rm -rf "$dir/tmp"` |
| `apps/ios-frontend/ios/build-imagemagick.sh` | B 49: `rm -rf "$work"; mkdir -p "$work" "$prefix"` |
| `apps/ios-frontend/ios/run-unit-tests.sh` | none |
| `apps/smoke-tests/android-lock.sh` | B 122: `rm -f "$LOCK_FILE"` |
| `apps/smoke-tests/android-lock.test.sh` | B 16: `rm -rf "$WORK"` |
| `apps/smoke-tests/lib/android.sh` | E 378: `adb shell rm -rf "$tmp_remote" >/dev/null 2>&1 \|\| true`<br>E 380: `adb shell run-as "$APP_ID" rm -rf "files/$rel_dest"`<br>E 385: `adb shell rm -rf "$tmp_remote" >/dev/null 2>&1 \|\| true`<br>B 410: `rm -f "$tmp_local"`<br>E 418: `adb shell rm -f "/data/local/tmp/$DATABASES_CONFIG_FILE" >/dev/null 2>&1 \|\| true`<br>B 419: `rm -f "$tmp_local"`<br>E 436: `result="$(adb shell pm clear "$APP_ID" 2>&1 \| tr -d '\r')"`<br>E 454: `adb shell run-as "$APP_ID" rm -rf "files/$rel" >/dev/null 2>&1 \|\| true`<br>E 487: `adb shell run-as "$APP_ID" rm -rf files >/dev/null 2>&1 \|\| true`<br>E 488: `adb shell rm -rf /data/local/tmp/50-assets >/dev/null 2>&1 \|\| true` |
| `apps/smoke-tests/lib/common.sh` | B 337: `rm -f "$tmp_dir/bridge.port"`<br>D 669: `pkill -P "$killer_pid" 2>/dev/null \|\| true` |
| `apps/smoke-tests/lib/ios.sh` | B 179: `rm -rf "$dest"`<br>E 219: `# emptying the container is not enough on its own; `simctl keychain reset` is what clears them. Call`<br>B 226: `rm -rf "$container/Documents/"* "$container/Library/"* "$container/tmp/"* 2>/dev/null \|\| true`<br>E 228: `if ! xcrun simctl keychain "${IOS_SIMULATOR_UDID:-booted}" reset >/dev/null 2>&1; then`<br>B 247: `rm -rf "$container/Documents/$rel" 2>/dev/null \|\| true`<br>B 287: `rm -rf "$container/Documents/"* 2>/dev/null \|\| true` |
| `apps/smoke-tests/lib/runner.sh` | B 56: `rm -f "$SUITE_REGISTRATION" "$SUITE_HELD_FILE" "$SUITE_HELD_LOCK"`<br>B 81: `rm -f "$registration" "$registration.held" "$registration.held.lock" 2>/dev/null \|\| true`<br>C 396: `mv "$queue_file.next" "$queue_file"`<br>B 534: `rm -rf "$dir/$RUN_TMP_NAME"`<br>B 634: `rm -rf "$work_dir"` |
| `apps/smoke-tests/runner.test.sh` | B 21: `rm -rf "$WORK"`<br>F 269: `chmod +x "$ACQUIRE_HELPER"`<br>B 271: `rm -f /tmp/photosphere-android-device-fakedev-*.lock`<br>B 330: `rm -f /tmp/photosphere-android-device-fakedev-*.lock` |
| `apps/smoke-tests/run.sh` | B 156: `rm -rf "$results_dir"` |
| `apps/smoke-tests/tests/0-launch-and-navigate/test.sh` | none directly; reaches a destructive helper: stop_app |
| `apps/smoke-tests/tests/10-view-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/11-edit-encryption-key/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/12-edit-api-key/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/13-edit-s3-credentials/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/14-rename-secret/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/15-duplicate-name/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/16-remove-recent-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/17-news-notifications/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/17-replicate-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _reset_path, _seed_database, stop_app |
| `apps/smoke-tests/tests/18-move-file/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/19-download-single-asset/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/1-load-fixture/test.sh` | none directly; reaches a destructive helper: _seed_database, stop_app |
| `apps/smoke-tests/tests/20-download-multiple-assets/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/21-import-video/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/22-edit-database-origin/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/26-receive-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/27-receive-secret/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/28-host-emulator-comms/test.sh` | none (adb shell echo and adb shell ping only, both read-only) |
| `apps/smoke-tests/tests/29-stale-recent-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/2-create-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _reset_path, stop_app |
| `apps/smoke-tests/tests/30-export-asset/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/31-create-database-no-collision/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _reset_path, stop_app |
| `apps/smoke-tests/tests/32-encrypted-database/test.sh` | B 61: `rm -rf "$CONFIG_SEED"` |
| `apps/smoke-tests/tests/34-sync/test.sh` | B 38: `rm -rf "$LOCAL_FIXTURE"` |
| `apps/smoke-tests/tests/35-database-summary/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/36-prefetch-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _reset_path, _seed_database, stop_app |
| `apps/smoke-tests/tests/37-lan-share-timeout/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/39-secret-in-keychain/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/3-open-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/40-s3-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/4-import-photos/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/5-add-secret/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/6-add-database-entry/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/7-share-secret/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/tests/8-share-database/test.sh` | none directly; reaches a destructive helper: _reset_app_state, _seed_database, stop_app |
| `apps/smoke-tests/tests/9-view-secret/test.sh` | none directly; reaches a destructive helper: _reset_app_state, stop_app |
| `apps/smoke-tests/timeout.test.sh` | B 20: `rm -rf "$WORK"` |
| `cli-desktop-lan-share-smoke-tests.sh` | D 59: `pkill -f "bun run.*secrets (send\|receive)" 2>/dev/null \|\| true`<br>D 60: `pkill -f "bun run.*dbs (send\|receive)" 2>/dev/null \|\| true`<br>F 94: `chmod 600 "$vault_dir/$secret_name.json"`<br>F 116: `chmod 600 "$vault_dir/$secret_name.json"`<br>B 117: `rm -f "$pem_file"`<br>B 289: `rm -rf "$test_tmp"`<br>B 345: `rm -rf "$test_tmp"`<br>B 410: `rm -rf "$test_tmp"`<br>B 472: `rm -rf "$test_tmp"`<br>B 541: `rm -rf "$TMP_ROOT"` |
| `docs/testing/e2e/desktop/news/setup-news-feed.sh` | C 10: `cat > "$NEWS_FILE"` (NEWS_FILE is the literal /tmp/photosphere-news.yaml; clobbers it) |
| `.githooks/pre-commit` | none |
| `run-cloud-storage-tests.sh` | E 80: `node scripts/clear-s3-bucket.js "$TEST_S3_BUCKET"` |
| `run-tests.sh` | none |
| `scripts/check-flaky-tests.sh` | none directly; line 69 runs an arbitrary caller-supplied command (`mise exec -- bash -c "$*"`), so whatever that command destroys is reached from here |
| `scripts/fetch-mobile-media-tools.sh` | B 85: `rm -rf "$IM_DIR/include"`<br>B 99: `rm -rf "$buildDir"`<br>B 121: `rm -rf "$unpack"; mkdir -p "$unpack"` |
| `scripts/install-hooks.sh` | A 31: `git config core.hooksPath .githooks` |
| `scripts/s3-emulator.sh` | B 97: `rm -f "$partialPath"`<br>F 101: `chmod +x "$partialPath"`<br>C 102: `mv "$partialPath" "$binaryPath"`<br>B 153: `rm -f "$stateDir/minio.log"`<br>B 171: `rm -f "$stateDir/minio.pid" "$stateDir/minio.port"`<br>B 190: `rm -rf "$stateDir/data" "$stateDir/env"`<br>B 254: `rm -f "$pidFile" "$stateDir/minio.port"` |
| `scripts/story-player.sh` | B 463: `rm -rf "$TMP_DIR"`<br>B 493: `rm -rf "$SCREENSHOTS_DIR"` |
| `scripts/test-everything-parallel.sh` | B 120: `rm -rf "$LOG_DIR"` |
| `scripts/update-mobile-media-tools.sh` | C 81: `perl -pi -e "$@" "$file"` |
| `test/test-cli-commands.sh` | C 37: `> /tmp/summary_${db//\//_}.log`<br>C 48: `> /tmp/verify_${db//\//_}.log` (clobbers fixed-name files in the shared /tmp) |
| `tools/what-changed/smoke-tests.sh` | B 36: `rm -rf "$WORK_DIR"`<br>B 139: `rm -f "$WORK_DIR/what-changed.json"` |

## Ranked list of what to fix first

Ranked by blast radius, not by how easy the fix is. No fixes are applied here and none are described in detail.

1. **`run-cloud-storage-tests.sh`**, deletes every object in a bucket whose name comes from an environment variable, with nothing but two interactive prompts between a mistyped `TEST_S3_BUCKET` and permanent data loss in cloud storage. The largest blast radius in the repository, and the only one that reaches outside the machine.
2. **`apps/smoke-tests/lib/runner.sh:534`**, an unvalidated environment variable is used as a path suffix in `rm -rf`, so `PHOTOSPHERE_TEST_TMP=..` deletes the mobile test suite out of the working tree. Reaches every mobile smoke test through a single line in a shared library.
3. **`apps/cli/smoke-tests.sh` and `apps/cli/smoke-tests-encrypted.sh`**, a documented `--tmp-dir <dir>` option feeds an unguarded `rm -rf`, and both scripts have a `reset` command whose entire job is to run it. Two of the six sites are the exact "delete the directory the user named" shape. The same file already demonstrates the fix at line 525 (`${TEST_TMP_DIR:?}`), which makes the omission at the other four sites harder to defend.
4. **`scripts/story-player.sh:493` and `apps/desktop/screenshots/capture-ux.sh:24`**, a documented `--screenshots <dir>` option and an `OUT_DIR` environment variable feed `rm -rf`. Both are aimed at directories a developer would plausibly point at somewhere real, because the whole purpose of the option is to choose where output goes.
5. **`apps/smoke-tests/lib/android.sh:436, 487`**, `adb shell pm clear` and `rm -rf files` target whatever device adb happens to be talking to, and the device-discovery function accepts real phones, not only emulators. Blast radius is another machine's app data, which no amount of local care protects.
6. **`apps/cli/smoke-tests-lan-share.sh` and `cli-desktop-lan-share-smoke-tests.sh`**, five and two `pkill -f` calls on patterns broad enough to match a developer's own `bun` processes. Kills work in progress rather than deleting files, so the damage is recoverable, but it is silent and happens on every run.
7. **`apps/android-frontend/scripts/emulator.sh:313`**, `ip link del` on an interface named by an environment variable, running as root through `sudo`. Only reachable by invoking the internal `__bridge-down` subcommand directly, which is why it ranks below the others, but the consequence is losing the machine's network.
8. **`apps/cli/smoke-tests.sh:642, 748, 930, 1000`**, `hash-cache clear` wipes a cache in the system temp directory that the user's real `psi` runs share. Nothing is permanently lost, only re-computed, but it is a test reaching outside its own sandbox.
9. **`apps/desktop/scripts/test-post-install.sh:82, 86`**, `sudo chown root:root` on a path derived from `$1`. Narrow (the file must be named `chrome-sandbox`) but it leaves a root-owned setuid file the caller cannot undo.
10. **`apps/cli/diff-dirs.sh:157`**, an unquoted expansion inside a `trap "rm -rf $TMPDIR"` string. Small blast radius and unlikely to fire, but it is the cheapest thing on this list to get wrong again, and the whole trap idiom is copied elsewhere in the repository.
11. **`scripts/install-hooks.sh:31`**, `git config core.hooksPath .githooks` overwrites a setting whose previous value the script reads and prints but does not restore. Listed for completeness: it is deliberate, it is the point of the script, and the file is frozen.

## Notes

- The one guarded deletion in the entire repository is `apps/cli/smoke-tests.sh:525`, `rm -rf "${TEST_TMP_DIR:?}/${dir_name}"`. Every other deletion of a variable-rooted path is unguarded.
- `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd`, `sed -i`, `chmod -R` and `chown -R` have zero occurrences anywhere in the 185 scripts. `docker`, `aws s3 rm`, `avdmanager delete` and `adb uninstall` likewise have zero occurrences.
- Only three scripts invoke git at all, and only one mutates repository state. The `git init` / `git add -A` accident that motivated this audit is not repeatable from any script currently in the repository: `tools/what-changed/smoke-tests.sh` now only mentions those commands in a comment explaining why it does not run them.
- 171 `trap` statements were found across 154 files. The dangerous placement the plan warned about (a trap whose target variable is assigned after the trap is installed) was not found for any deletion: every `rm -rf` in a trap has its target assigned on the line before. It was found for `$APP_PORT` in the app-lifecycle traps, listed under Unproven, where nothing destructive follows from it.
- A repeatable scanner was deliberately not written. The greps in this document are reproducible from the method section, but the ratings are not mechanical, and a scanner that could not reproduce them would have to say "none" about scripts it had not really checked.
