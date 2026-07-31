# Audit every shell script for destructive commands

## Overview

This repository contains 183 tracked `.sh` files (count taken during research for this plan) plus a small number of shell scripts without a `.sh` extension. Many of them delete directories, and at least one changes git repository state. Nobody currently knows the full list, which means nobody knows how many of those deletions target a path that could be empty, unset, or computed wrongly at the moment the command runs. A `rm -rf "$SOME_DIR"` with `SOME_DIR` unset deletes from the root; the same command with `SOME_DIR` computed wrongly deletes something real. This has already happened once in this repository with `git init` and `git add -A` in a smoke test, which landed on the real repository and overwrote the branch pointer and the index.

This plan is a read-only audit. It produces one document, `docs/destructive-command-audit.md`, listing every shell script in the repository, the destructive commands each one contains with file and line, and an explicit "none" entry for every script that contains no destructive command. It fixes nothing. A fix folded into an audit destroys the evidence of how bad the audit was, and each fix deserves its own justification.

## Issues

## Steps

This plan changes no source files and no shell scripts. Steps 1 to 6 read and accumulate findings; step 7 writes them up; step 8 checks the write-up is complete.

**Two rules that hold for every step below.** First, do not execute any script under audit, and do not run any destructive command to "see what it does". This audit is performed by reading. Second, do not edit any script under audit, including the ones with the worst findings. Fixes are separate work.

### Step 1: Build the exhaustive script inventory

Produce the list of every shell script in the repository. The list must come from a command, not from memory or from a directory walk done by eye.

- `git ls-files '*.sh'` gives the tracked `.sh` files.
- `git status --porcelain --untracked-files=all` filtered to `.sh` gives untracked and modified scripts, which are in the working tree and can run, and therefore belong in the audit.
- Shell scripts without a `.sh` extension exist and must be found and included. Known at research time: `.githooks/pre-commit` and `apps/android-frontend/android/gradlew`. Find the rest by listing tracked files whose name has no recognised extension and checking each for a shell shebang.

Record the total count. Write the inventory to a working file under the scratchpad directory (not into the repository) so later steps can reconcile against it.

Two classification decisions to record in the inventory rather than silently apply:

- `apps/android-frontend/android/gradlew` is vendored third-party code. Include it in the report with its findings, marked as vendored, and do not propose changing it.
- `apps/desktop/scripts/setup-electron-builder.ps1` is PowerShell, not shell. Include it in the report as a separate short section rather than dropping it, since it can destroy state the same way.

### Step 2: Define the pattern catalogue and grep the whole set

Grep the full inventory for each category below and record every hit as file, line and the exact line text. Greps are the first pass only; step 3 exists because greps miss the indirect forms.

- **Category A, git repository state.** `git init`, `git add`, `git commit`, `git config`, `git checkout`, `git reset`, `git restore`, `git rm`, `git stash`, `git branch`, `git merge`, `git rebase`, `git push`, `git tag`, `git clean`, `git worktree remove`, `git filter-branch`. Read-only git (`git ls-files`, `git status`, `git log`, `git diff`, `git rev-parse`) is not a finding, but count how many scripts use git at all so the report can state that the git usage was looked at in full.
- **Category B, recursive or forced deletion.** `rm -rf`, `rm -r`, `rm -f`, and any `rm` whose flags include `r`, `R` or `f` in any order or combination.
- **Category C, other deletion, overwrite or truncation of existing state.** Plain `rm`, `rmdir`, `find` with `-delete` or `-exec rm`, `shred`, `truncate`, `dd`, `sed -i`, `mv` onto a path that may already exist, `cp` over an existing file, and `>` redirection that clobbers an existing file. The `>` case needs judgement: writing a fresh log into a temp directory the script just created is not a finding, overwriting a file that is part of the repository or the user's environment is.
- **Category D, process destruction.** `kill`, `pkill`, `killall`, and any helper that wraps them (`kill_app_tree` is known to exist). Killing a process the script started is low risk; a `pkill` matching a name pattern can kill a process the user started and is a finding.
- **Category E, destruction outside the local filesystem.** Deletion on a connected device or emulator (`adb shell rm`, `adb ... run-as ... rm`, `adb uninstall`, `simctl erase`, `simctl delete`), container and image removal (`docker rm`, `docker rmi`, `docker prune`), object storage deletion (`aws s3 rm`, `s3 rb`, any MinIO or bucket delete), and database drop or truncate.
- **Category F, recursive permission or ownership change.** `chmod -R`, `chown -R` over any path the script did not create.

Note from research: category B alone has well over thirty hits, `kill` appears on roughly 70 lines, `pkill` on 10, and `trap` on roughly 171. These numbers are indicative of scale only. Do not carry them into the report; produce fresh counts.

### Step 3: Read every script end to end

Greps find the direct forms. Read every script in the inventory in full and look for the forms a grep cannot see:

- A destructive command assembled in a variable and expanded later, so the literal `rm` never appears next to its flags.
- A destructive command inside a `trap` handler. Traps are the highest-risk placement in this repository, because a trap can fire before the variable holding its target has been assigned, and because it runs on paths the author never exercised. `apps/cli/demo-news.sh` and `apps/cli/diff-dirs.sh` both put `rm -rf` in a trap; there will be others.
- A destructive command reached through a shared helper library. `apps/smoke-tests/lib`, `apps/cli/smoke-tests/lib`, `apps/cli/smoke-tests-key-chain/lib` and `apps/desktop/smoke-tests/lib` are sourced by many tests, so one destructive line there applies to every caller.
- A shell script that invokes a `bun`, `node` or TypeScript entry point which then deletes things. Record this as a finding against the shell script, name the program it calls, and mark it as indirect. Do not follow the chain further than the immediate callee; a full audit of TypeScript deletion is separate work and should be named as such in the report.
- A destructive command passed to a remote shell, most importantly `adb shell` and `adb ... run-as`, where the path is interpreted on the device, not locally.

### Step 4: Trace the shared helpers once

For every helper library and every helper function found in step 3 that performs a destructive action, produce one entry recording the helper's file and line, what it destroys, and the full list of scripts that source or call it. The per-script entries in the report then reference that helper entry instead of repeating the analysis. This keeps the report honest about how widely one risky helper reaches.

### Step 5: Risk-assess every occurrence

For each occurrence recorded in steps 2 to 4, determine and record:

- **Target expression.** The literal path, or the variable, or the computed expression being destroyed.
- **Can the target be empty or unset at this line?** Check whether the script runs under `set -u`, whether the variable is assigned unconditionally before this point on every path including error paths and trap paths, and whether a guard such as `${VAR:?}` is used. `apps/cli/smoke-tests.sh:525` uses `${TEST_TMP_DIR:?}` and is the pattern the rest should be measured against.
- **Can the destruction escape its intended directory?** Decide whether the target is guaranteed to sit under a temporary or scratch directory that this script created. A target derived from a user-supplied argument, from the current working directory, or from an environment variable set outside the script cannot be guaranteed and is a finding regardless of how it looks.
- **Blast radius if it goes wrong.** State plainly what would be destroyed: a scratch directory, the repository working tree, the user's home directory, the device's app data, a storage bucket.

Assign each occurrence one of three ratings, and define the ratings in the report so they can be applied again later:

- **Safe.** Target is a literal or a guarded variable, provably inside a directory the script created, and unreachable with the variable unset.
- **Unproven.** Probably fine in practice but the guarantee cannot be established by reading, for example a trap whose target is assigned early but not before the trap is installed.
- **Dangerous.** The target can be empty, unset or outside the script's own scratch area on some reachable path, or the command mutates git repository state, or it deletes state the user did not ask to lose.

The rating must come from the specific reasoning above. "Looks fine" is not a rating; state the reachable path that makes it unsafe, or state what makes it provably safe.

### Step 6: Handle the frozen and intentional cases explicitly

Three files are frozen by project rule and must not be edited: `.githooks/pre-commit`, `scripts/install-hooks.sh` and `scripts/test-everything-parallel.sh`. They are still audited and still appear in the report with their findings. `scripts/install-hooks.sh` runs `git config core.hooksPath .githooks`, which is a category A repository-state mutation and must be listed as such; the report notes it is deliberate, is the mechanism that installs the hooks, and is frozen. Do not soften the classification because the command is intended. The report distinguishes "destructive" from "wrong"; conflating them makes the list useless.

Similarly, a smoke test deleting its own `tmp/` directory before a run is expected behaviour and still gets listed. The point of the document is a complete inventory, not a list of bugs.

### Step 7: Write the report

Create `docs/destructive-command-audit.md` containing, in this order:

1. **Headline numbers in the first paragraph.** Total scripts audited, how many contain at least one destructive command, and how many occurrences are rated dangerous. If the dangerous count is bad, it says so in that paragraph rather than further down.
2. **Scope and method.** What was counted as a shell script, what was counted as destructive (the category list from step 2), what the three ratings mean, and what was explicitly out of scope (deletion performed inside TypeScript or JavaScript reached from a script, beyond naming the immediate callee).
3. **Findings by rating.** Every dangerous occurrence first, then every unproven one, each with file and line, the command, the target expression, the reachable path that makes it unsafe, and the blast radius.
4. **Shared helpers.** One entry per destructive helper, with its callers, as produced in step 4.
5. **The full script inventory.** Every script in the repository, one row each, in path order, with either its destructive commands (category, file line, command) or the word "none". This table is the deliverable the request asked for and must contain every entry from step 1's inventory with no omissions.
6. **Ranked list of what to fix first.** Ranked by blast radius, not by how easy the fix is. Each entry names the script and what makes it dangerous. No fixes are applied here and none are described in detail.

Do not use em dashes. Do not use `---` horizontal rules. Do not hard-wrap paragraphs. Use repo-relative paths only, never a home-directory or machine-specific absolute path.

### Step 8: Reconcile the report against the inventory

Mechanically check that the inventory table in the report contains exactly the set of files from step 1, no more and no fewer, by comparing the paths in the table against the scratchpad inventory file. A script missing from the table is the failure mode this whole audit exists to prevent, so this check is not optional and its result goes in the report's method section.

Then check that every occurrence recorded in steps 2 to 4 appears in the report exactly once, and that every occurrence carries a rating and a stated reason.

## Unit Tests

None. This plan changes no functions and adds no code. Every new or changed function would require a unit test; there are none.

## Smoke Tests

None. Adding a smoke test here would mean writing a script that runs destructive commands to check destructive commands are detected, which is exactly the class of code this audit exists to find. A repeatable scanner was considered and deliberately left out; see Notes.

## Verify

- `git status` shows exactly one added file, `docs/destructive-command-audit.md`, and no modified file. Any modified script means step 1 or step 3 edited something it was only supposed to read.
- The inventory reconciliation in step 8 passes: the set of paths in the report's inventory table equals the set produced by step 1.
- Every row in the inventory table has either at least one listed command or the word "none". No blank cells.
- Every dangerous and unproven occurrence names a specific reachable path or a specific missing guarantee, not a general impression.
- Every occurrence's file and line is checked against the current file contents, so no line number is stale.
- `bun run compile` succeeds, and `bun run test:everything` passes. This is a formality for a docs-only change: the change gate will find no watched path modified and run nothing. Run `bun run everything:plan` first and confirm it reports nothing to run, which is itself evidence that no source file was touched.

## Notes

- **Fix nothing in this plan.** The value of the document is the number it produces. A fix applied during the audit removes the evidence for that number and gets rationalised in the moment, which is how the current situation arose.
- **A repeatable scanner was considered and rejected for now.** A `tools/` script that greps and emits this markdown would keep the document current, and it is a reasonable follow-up. It is out of scope here because the request is for the audit itself, because the first pass needs human-grade reading of traps and helpers that a grep cannot do, and because the scanner would need its own tests before it could be trusted to say "none" about a script. Write the document first; if it proves worth maintaining, automate the parts that turn out to be mechanical.
- **Destructive is not the same as wrong.** Most `rm -rf` in this repository is a smoke test clearing its own scratch directory, which is expected. The report lists them anyway and separates the classification (is it destructive) from the rating (is it safe). Anything else produces a document that quietly omits the commands somebody decided were fine, which is where the next accident will come from.
- **Traps deserve the most attention.** They are the placement where the target variable is least likely to be assigned on every path that reaches the command, and they run on error and interrupt paths that nothing exercises.
- **Do not run the scripts.** The audit is performed by reading. Running a script to find out what it deletes is a fine way to find out what it deletes.
- Untracked and modified working-tree scripts are included because they can run. If any is a scratch file that should not be in the repository, say so in the report rather than deleting it.

## Next

Recommend running:

- `/plan:check` to analyse this plan for problems.
- `/plan:simp` if it looks over-engineered.
