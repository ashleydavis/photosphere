# Destructive command audit

## Headline numbers

The audit covered every shell script in the repository at the time it was made. Most of those scripts have since been removed with the apps they belonged to, and their entries are gone from this document. What is left covers the audited scripts that are still in the repository. Scripts added since the audit have not been audited. One deletes every object in a named S3 bucket, and one is a mistyped argument away from deleting a real directory: `bun run stories:ziggy -- --screenshots <dir>`.

This document fixes nothing. It is an inventory.

## Scope and method

### What was counted as a shell script

The inventory came from commands, not from memory:

- `git ls-files '*.sh'` produced 183 tracked shell scripts.
- `git status --porcelain --untracked-files=all` was run against the main working copy and reported no untracked or modified shell scripts, so nothing was added on that account.
- Every other tracked file was checked for a `#!` first line. Shell scripts with no `.sh` extension were added, among them `.githooks/pre-commit`.

### What was counted as destructive

Six categories, greped across the whole inventory and then confirmed by reading each script end to end:

- **A, git repository state.** `git init`, `add`, `commit`, `config`, `checkout`, `reset`, `restore`, `rm`, `stash`, `branch`, `merge`, `rebase`, `push`, `tag`, `clean`, `worktree remove`, `filter-branch`. Read-only git is not a finding. Of the audited scripts still in the repository, only `scripts/install-hooks.sh` runs git, and it mutates repository state.
- **B, recursive or forced deletion.** Any `rm` whose flags include `r`, `R` or `f`.
- **C, other deletion, overwrite or truncation of existing state.** Plain `rm`, `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd`, `sed -i`, `perl -pi`, `mv` onto a path that may exist, `cp` over an existing file, and `>` redirection that clobbers an existing file. Judgement was applied to the `>` case, as the plan required: writing a fresh log or a fresh config into a temporary directory the script itself created is not listed; overwriting a file that is part of the repository, of the user's environment, or of a shared directory such as `/tmp` is listed. `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd` and `sed -i` have zero hits anywhere in the repository.
- **D, process destruction.** `kill`, `pkill`, `killall` and the helpers that wrap them. Killing a process the script itself started is low risk and is listed against the helper rather than repeated for every caller. A `pkill` matching a name pattern is listed as its own occurrence.
- **E, destruction outside the local filesystem.** Deletion on a connected device or emulator (`adb shell rm`, `adb ... run-as ... rm`, `adb shell pm clear`, `simctl keychain reset`), host network state (`ip link del`, `iptables -D`, `sysctl -w`), object storage deletion, OS keychain deletion, and the CLI's own `hash-cache clear`.
- **F, recursive permission or ownership change.** `chmod -R` and `chown -R` have zero hits. `chown`/`chmod` on a path the script did not create is listed instead.

### What the ratings mean

- **Safe.** The target is a literal, or a variable whose value is built only from the script's own location or from `mktemp`, it is provably inside a directory the script created, and it cannot be reached with the variable unset or empty.
- **Unproven.** Probably fine in practice, but the guarantee cannot be established by reading. The usual cause here is an environment variable that has a sensible default but that the caller can point anywhere.
- **Dangerous.** The target can be empty, unset, or outside the script's own scratch area on some reachable path; or the command mutates git repository state; or it deletes state the user did not ask to lose.

Destructive is not the same as wrong. Most of the `rm -rf` in this repository is a smoke test clearing its own scratch directory, which is expected behaviour and is listed anyway. The classification (is it destructive) is kept separate from the rating (is it safe).

### What was out of scope

Deletion performed inside TypeScript or JavaScript reached from a shell script was not audited beyond naming the immediate callee. A full audit of deletion in the TypeScript sources is separate work and has not been done.

The audit was performed by reading. No script under audit was executed, and no script under audit was edited.

### What the inventory table lists

The table lists every occurrence found by the category greps for A, B, D (pattern-matching kills only), E and F, plus the category C occurrences judgement kept: deletion, overwrite or truncation of state that already exists outside a scratch directory the script itself created. Two things are deliberately not repeated per row, because doing so would bury the findings that matter under a hundred identical entries:

- `kill` of a pid the script recorded itself, or of its own job list. These are summarised under Safe.
- `>` redirection of a log, a port file or a seeded config into a temporary directory the script created moments earlier.

Neither omission hides an occurrence rated above safe. Both are stated here so that a "none" in the table is read as "no destructive command in the categories above", not as "this script writes nothing".

### Reconciliation

When the audit was made, the set of paths in the inventory table was compared mechanically against the inventory the commands above produced, and the two sets were equal, with no duplicates. Rows for scripts removed since have been taken out. Every row has either at least one listed command or the word "none"; no cell is blank.

## Findings by rating

### Dangerous

**1. `scripts/story-player.sh:466`, a caller-named directory.**
Command: `rm -rf "$SCREENSHOTS_DIR"`. Target expression: `$SCREENSHOTS_DIR`, taken verbatim from `--screenshots <dir>` (line 75) with the default `$REPO_DIR/stories-screenshots/<platform>`. Reachable path: `bun run stories:ziggy -- --screenshots <a-real-directory>` deletes that directory. The `--screenshots <dir>` option is documented in CLAUDE.md as a supported way to run the story player. Blast radius: any directory the caller names.

**2. `scripts/install-hooks.sh:31`, git repository state.**
Command: `git config core.hooksPath .githooks`. This is a category A mutation of the repository's own configuration and is classified as destructive because it overwrites whatever `core.hooksPath` was set to (the script prints the previous value at line 28 but does not preserve it). It is deliberate: it is the mechanism that installs the hooks, and the file is frozen by project rule. The classification is not softened; the rating records what the command does, not whether somebody wanted it.

### Unproven

**`docs/testing/e2e/desktop/news/setup-news-feed.sh:10`, a fixed path in the shared /tmp.**
`cat > "$NEWS_FILE"` where `NEWS_FILE="/tmp/photosphere-news.yaml"` clobbers a predictable path in the shared `/tmp`. A pre-existing symlink at that path is followed.

**`scripts/s3-emulator.sh:367`, a caller-named state directory.**
`rm -rf "$stateDir/data" "$stateDir/env"` where `stateDir` is the script's second argument. The literal `/data` and `/env` suffixes contain the damage to two named children, but the parent is arbitrary. Reached through `bun run s3-emulator` from `start_s3_emulator` in `apps/cli-zig/smoke-tests/lib/common.sh` and in `apps/photosphere-smoke-tests/lib/common.sh`.

**Trap-ordering: `$APP_PORT` referenced before it is assigned.**
`scripts/story-player.sh:461` installs `trap cleanup EXIT` where `cleanup` calls `stop_app "$APP_PORT"` at line 448. It does so before `start_app` (line 474) assigns `APP_PORT` (`apps/photosphere-smoke-tests/lib/common.sh:214`). If the script exits before `start_app` returns, the trap runs with `APP_PORT` unset, and `stop_app` sends `quit` to an empty port before cleaning up the apps recorded under `$TMP_DIR`. It is the exact placement the plan flags: a trap whose target is not assigned on every path that reaches it.

### Safe

The remaining occurrences are rated safe and are not itemised individually here; each appears in the inventory table with its file and line. They fall into these shapes:

- A path built from `$(mktemp -d)` assigned before the trap that deletes it (`scripts/test-everything-parallel.sh:180`).
- A path built from `$(dirname "${BASH_SOURCE[0]}")` or from `find` output rooted at the script's own directory (`scripts/story-player.sh:435`).
- A `kill` of a pid the script itself recorded, or of its own job list (`scripts/story-player.sh:440-454`, `scripts/test-everything-parallel.sh:159-175`, `scripts/s3-emulator.sh:440-443`).

## Full script inventory

Every audited script that is still in the repository, one row each. Scripts added since the audit are not listed. Categories are A (git state), B (recursive or forced deletion), C (other deletion, overwrite or truncation), D (process destruction), E (destruction outside the local filesystem), F (permission or ownership change).

| Script | Destructive commands |
| :-- | :-- |
| `docs/testing/e2e/desktop/news/setup-news-feed.sh` | C 10: `cat > "$NEWS_FILE"` (NEWS_FILE is the literal /tmp/photosphere-news.yaml; clobbers it) |
| `.githooks/pre-commit` | none |
| `run-tests.sh` | none |
| `scripts/install-hooks.sh` | A 31: `git config core.hooksPath .githooks` |
| `scripts/s3-emulator.sh` | F 187: `chmod +x "$partialPath"`<br>C 192: `mv "$partialPath" "$binaryPath"`<br>B 200: `rm -f "$partialPath"`<br>B 329: `rm -f "$stateDir/minio.log"`<br>B 347: `rm -f "$stateDir/minio.pid" "$stateDir/minio.port"`<br>B 367: `rm -rf "$stateDir/data" "$stateDir/env"`<br>B 446: `rm -f "$pidFile" "$stateDir/minio.port"` |
| `scripts/story-player.sh` | B 435: `rm -rf "$TMP_DIR"`<br>B 466: `rm -rf "$SCREENSHOTS_DIR"` |
| `scripts/test-everything-parallel.sh` | B 180: `rm -rf "$LOG_DIR"` |

## Ranked list of what to fix first

Ranked by blast radius, not by how easy the fix is. No fixes are applied here and none are described in detail.

1. **`scripts/story-player.sh:466`**, a documented `--screenshots <dir>` option feeds `rm -rf`. It is aimed at a directory a developer would plausibly point at somewhere real, because the whole purpose of the option is to choose where output goes.
2. **`scripts/install-hooks.sh:31`**, `git config core.hooksPath .githooks` overwrites a setting whose previous value the script reads and prints but does not restore. Listed for completeness: it is deliberate, it is the point of the script, and the file is frozen.

## Notes

- `rmdir`, `find -delete`, `find -exec rm`, `shred`, `truncate`, `dd`, `sed -i`, `chmod -R` and `chown -R` had no occurrences anywhere in the audited scripts. `docker`, `aws s3 rm`, `avdmanager delete` and `adb uninstall` likewise had none.
- Of the audited scripts still in the repository, only `scripts/install-hooks.sh` invokes git. The `git init` / `git add -A` accident that motivated this audit is not repeatable from any of them.
- 171 `trap` statements were found across 154 files. The dangerous placement the plan warned about (a trap whose target variable is assigned after the trap is installed) was not found for any deletion: every `rm -rf` in a trap has its target assigned on the line before. It was found for `$APP_PORT` in the app-lifecycle traps, listed under Unproven, where nothing destructive follows from it.
- A repeatable scanner was deliberately not written. The greps in this document are reproducible from the method section, but the ratings are not mechanical, and a scanner that could not reproduce them would have to say "none" about scripts it had not really checked.
