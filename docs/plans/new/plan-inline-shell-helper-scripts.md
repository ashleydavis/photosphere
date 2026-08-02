# Re-assess the eight shell helper scripts and inline the ones shell can do

## Overview

Commit `8d2ab851` ("Removed every other language from the shell scripts") removed `python3` and embedded `bun -e`/`node -e` snippets from twelve shell scripts. Where it could, it rewrote them as shell. Where it judged shell could not do the job, it created eight new TypeScript helpers under `scripts/`, invoked as `bun scripts/<name>.ts <args>`. That judgement was made once, quickly, per site, and some of it looks too generous: at least three of the eight have a plain shell answer that was not tried. Every helper that stays is a `bun` process spawned per call inside a smoke test, plus a file to maintain, so each one should have to earn its place.

This plan re-examines each of the eight helpers on its merits, decides whether it is genuinely required, and where it is not, folds the work back into the calling shell script as real shell (not as an embedded JavaScript or TypeScript string, which `CLAUDE.md` bans outright). The work is fanned out to one git worktree per helper, `inline-helper-1` through `inline-helper-8`, so the eight investigations run in parallel and the human can review each worktree's diff in turn.

Important: the commit and all eight helpers live on branch `fix-mobile-release-workflow`, not on `mobile` (the branch currently checked out in the main worktree) and not on `main`. Every worktree in this plan must be branched from `fix-mobile-release-workflow`, otherwise the helper files will not exist in it.

## Issues

## Steps

### Step 1: Confirm the verdict table and the base branch (human approval gate, no code changes)

The AI agent presents the table below to the human and waits for a decision on each row before creating any worktree. The verdicts are the AI's preliminary reading from the research already done; the human may change any of them. The agent must also confirm that `fix-mobile-release-workflow` is the correct base branch for all eight worktrees.

| # | Helper | Call sites | Preliminary verdict | Shell answer to try |
|---|--------|-----------|--------------------|--------------------|
| 1 | `scripts/find-free-port.ts` | 1 (`scripts/s3-emulator.sh`) | Inline | `bash` `/dev/tcp` probe over a `$RANDOM`-picked high port, retrying until one is closed |
| 2 | `scripts/json-encode.ts` | 3 (`apps/cli/smoke-tests/lib/common.sh`, `apps/cli/smoke-tests-key-chain/lib/common.sh`, `apps/smoke-tests/tests/32-encrypted-database/test.sh`) | Split: inline `--url-segment`, assess `--string` | Percent-encoding loop in shell for the URL segment; JSON string escaping is the harder half |
| 3 | `scripts/list-test-scripts.ts` | 1 (`scripts/check-flaky-tests.sh`) | Assess | Needs JSON key extraction from `package.json`; check whether a non-parsing answer exists |
| 4 | `scripts/read-database-state-field.ts` | 1 (`apps/cli/smoke-tests/64-config-timestamps/test.sh`) | Assess, leaning keep | Little-endian binary decode; `od` can do it but `--endian` is GNU-only |
| 5 | `scripts/read-json-field.ts` | 9 (five Electron tests, two CLI tests) | Keep | None: reads values that are multi-line PEMs and embedded JSON |
| 6 | `scripts/replace-in-file.ts` | 1 (`scripts/update-mobile-media-tools.sh`) | Inline, subject to the note below | `sed` to a temporary file then replace the original |
| 7 | `scripts/resolve-electron-binary.ts` | 1 (`apps/desktop/smoke-tests/lib/common.sh`) | Inline | Read `node_modules/electron/path.txt`, join onto `node_modules/electron/dist/`, checking the app dir then the workspace root |
| 8 | `scripts/write-vault-secret.ts` | 10 (Electron, CLI, LAN-share suites) | Keep | None: builds JSON whose value is a multi-line PEM or an embedded JSON document |

Two things the agent must raise explicitly at this gate, because they need a decision the AI is not allowed to make on its own:

- Helper 6's shell answer replaces a file in place. Every portable form of that (`sed ... > tmp && mv tmp file`, or writing over the original) is a destructive command under the user's standing rule, so the agent must not write it without explicit approval in the approving message. If approval is withheld, helper 6 keeps its TypeScript helper and the worktree records why.
- `CLAUDE.md` line 39 currently cites "binding a socket to find a free port" as the canonical example of something that must be a TypeScript helper. If helper 1 is inlined, that sentence becomes wrong and needs rewording. The agent must not edit `CLAUDE.md` until Step 5.

Complete when: the human has given a verdict for each of the eight rows and confirmed the base branch.

### Step 2: Create the eight worktrees

Only after Step 1 approval. For each helper number `N` from 1 to 8 that the human approved for investigation, the agent runs, from the main checkout:

```
git worktree add -b inline-helper-N .claude/worktrees/inline-helper-N fix-mobile-release-workflow
```

Then in each worktree, `bun install` so `node_modules` is present (the Electron and CLI suites will not run without it).

The agent must not use `EnterWorktree` with a `name` parameter; it uses the `path` parameter after the explicit `git worktree add` above, per `CLAUDE.md`.

Complete when: `git worktree list` shows the eight new worktrees and each has a populated `node_modules`.

### Step 3: Run the eight investigations in parallel

Each worktree gets one agent with the same brief, parameterised by its helper. The agent's job in worktree `inline-helper-N`:

1. Read `scripts/<helper>.ts` and every call site listed for it in the Step 1 table.
2. Determine what the helper actually does for each caller, as opposed to what its comment block claims it does. Several comment blocks assert "there is no shell answer"; that claim is the thing under test and must not be taken as evidence.
3. Attempt the shell answer named in the table. Run it against the real inputs the callers pass, not invented ones. For example helper 2's URL-segment mode must be checked against a secret name of the shape `shared:abc123`, and helper 7 must be checked with the `electron` package both hoisted to the workspace root and present in `apps/desktop/node_modules`.
4. If the shell answer works and is not materially worse than the helper, rewrite the call sites to use it, delete `scripts/<helper>.ts`, and grep the whole repository (excluding `node_modules` and `.git`) for the helper's name to confirm no reference survives, including in `docs/` and in `.github/workflows/`.
5. If the shell answer does not work, leave the helper in place, and write down exactly what was tried and what broke. A verdict of "keep" is only acceptable with a concrete failure behind it.
6. Where the change is to a shared shell function used from more than one script (helper 2 touches `seed_vault_secret` in two `lib/common.sh` files), make the same change in both.
7. Run the suites named for that helper in the Smoke Tests section below. Record which ran, which passed, and which could not be run in this environment (the key-chain suite needs a system keyring, mobile test 32 needs an Android emulator).
8. Write one summary document per helper script, `docs/plans/new/inline-helper-N-findings.md`, in that worktree. There is exactly one of these per helper, and it is the human's entry point when reviewing that helper's work. It must record, at minimum:

    - **Helper**: the helper script's name, for example `scripts/find-free-port.ts`.
    - **Where the code is waiting for review**: the name of the work holding the changes, that is the branch name `inline-helper-N` and the worktree path `.claude/worktrees/inline-helper-N`. State this near the top, so the human can go straight to it.
    - **What was done**: a plain summary of the change made to the helper and its call sites: whether the helper was deleted, reduced, or left alone, and which files were edited.
    - **Verdict and why**: inline or keep, with the concrete evidence behind it. A verdict of "keep" needs a named failure, not an opinion.
    - **The shell replacement in full**, where there is one, and the real inputs it was checked against.
    - **Tests**: the suites that were run and their results, plus any that could not be run in this environment and why.
    - **Not verified**: anything the agent could not check.

The agent must not commit, stage, or otherwise change git state in its worktree. It leaves the changes in the working tree for the human to review.

Complete when: all eight worktrees have their per-helper summary document and either a working-tree diff or a documented reason there is none.

### Step 4: Report the eight results back

The AI agent that owns this plan collects the eight per-helper summary documents and presents one combined summary: for each helper, what was done, the verdict and why, which suites passed, which could not be run, and the name of the work where that helper's code is waiting for review (the branch and worktree path). It then stops and waits. The human reviews each worktree in turn.

Complete when: the summary is delivered, and it names, for every one of the eight helpers, a summary document and the branch its changes are waiting on.

### Step 5: Integration (only after the human has reviewed the worktrees)

This step is deliberately last and separate, because the worktrees overlap. These files are edited by more than one worktree:

- `apps/cli/smoke-tests/lib/common.sh` and `apps/cli/smoke-tests-key-chain/lib/common.sh`: helpers 2 and 8 both edit the `seed_vault_secret` function, adjacent lines.
- `apps/desktop/smoke-tests/11-edit-encryption-key/test.sh`, `13-edit-s3-credentials/test.sh`, `14-rename-secret/test.sh`: helpers 5 and 8 both edit these.

If the human accepts changes from two worktrees that touch the same file, they will conflict. The agent proposes a merge order at this point (helper 8's verdict first, since it is the one most likely to be "keep", then helper 5, then helper 2) but performs no git operation without an explicit instruction naming it.

Also in this step, and only with the human's approval: update `CLAUDE.md` line 39 so its examples match the helpers that survived, and update `docs/updating-mobile-imagemagick-ffmpeg.md` if helper 6 was inlined and that document references `replace-in-file.ts`.

Complete when: the human has directed which worktrees to integrate and the integration has been done as directed.

## Unit Tests

There are no unit tests to add. Every change in this plan is to shell script or to the deletion of a shell-invoked helper, and this repository does not unit-test shell. The existing helpers have no unit tests either, so nothing is being given up. The coverage for all of it is the smoke suites listed below, which exercise these code paths directly.

Where a worktree's verdict is "keep" and it changes the surviving `.ts` helper at all, that change must still type-check under `bun run compile`.

## Smoke Tests

No new smoke tests are written. Each worktree runs the existing suites that exercise its helper's call sites, and the point of the exercise is that these suites already cover the behaviour:

- Helper 1 (`find-free-port`): the S3 smoke tests, which start MinIO through `scripts/s3-emulator.sh`. Also run `bash scripts/s3-emulator.sh start <dir>` followed by `stop` directly and confirm the port written to `<dir>/env` is the one the server is listening on.
- Helper 2 (`json-encode`): `bun run test:cli` for the URL-segment path via `seed_vault_secret`. The key-chain suite and mobile test 32 cannot run in this environment (keyring, emulator); the worktree records them as unrun rather than claiming them.
- Helper 3 (`list-test-scripts`): `bash scripts/check-flaky-tests.sh --list` and compare its output line for line against the current output captured before the change.
- Helper 4 (`read-database-state-field`): `bun run test:cli -- 64`.
- Helper 5 (`read-json-field`): `bun run test:electron` (covers tests 11, 12, 13, 14, 22) and `bun run test:cli -- 49` and `bun run test:cli -- 50`.
- Helper 6 (`replace-in-file`): there is no automated test. `scripts/update-mobile-media-tools.sh` is run against a copy of the target build file in the worktree's own temporary directory, and the result diffed against what the current helper produces for the same input.
- Helper 7 (`resolve-electron-binary`): `bun run test:electron`, which fails to launch at all if the path is wrong.
- Helper 8 (`write-vault-secret`): `bun run test:electron` and `bun run test:cli`. If the verdict is "keep", running these confirms nothing regressed.

## Verify

Per worktree, before its summary document is written:

- `bun run compile` succeeds.
- The suites named for that helper above were run, and the summary document states the result of each, including any that could not be run and why.
- `docs/plans/new/inline-helper-N-findings.md` exists and carries every field listed in Step 3 item 8, including the branch and worktree path where the code is waiting for review.
- `grep -rn '<helper-name>' . --exclude-dir=node_modules --exclude-dir=.git` returns only the summary document when the verdict is "inline".

At the end, in whichever branch the accepted changes are integrated into:

- `bun run compile` succeeds.
- `bun run test:everything -- --force` passes, which is the canonical check for this repository and is what the git hook runs.

## Notes

- Evidence gathered while researching this plan, so the worktree agents do not have to rediscover it: `bash` `/dev/tcp` connection probing works on this machine; GNU `od` supports `--endian=little` but the BSD `od` on macOS does not, so helper 4's shell answer would have to decode bytes individually; `node_modules/electron/path.txt` exists at the workspace root and contains `electron`, with the executable at `node_modules/electron/dist/electron`; `apps/desktop/node_modules` does not currently contain `electron`, so the package is hoisted, but a shell answer must still check both locations.
- `jq` is installed on this machine and is already used once in `.github/workflows/release.yml`, but it is not declared in `mise.toml` (which pins only `bun` and `node`). It is therefore in exactly the position `python3` was in before commit `8d2ab851`: present by luck. A worktree agent must not reach for `jq` as the shell answer to a JSON problem without asking first.
- Helper 5 and helper 8 are the two strongest cases for keeping, and they are also the two with the most call sites (nine and ten). If both are kept, the deletions from this plan are concentrated in the single-call-site helpers, which is the expected shape: a helper invoked once is a helper whose existence is hardest to justify.
- Helper 2 is the one genuine split. Its `--url-segment` mode is percent-encoding, which shell can do; its `--string` mode is JSON string escaping, which is the thing `CLAUDE.md` names as a legitimate reason to have a helper. The worktree may end with the helper surviving in a reduced form rather than being deleted, and that is an acceptable outcome.
- The bug fix that commit `8d2ab851` mentions (a secret name interpolated into JavaScript source in `apps/cli/smoke-tests/lib/common.sh`, making a quote in a name into code injection) must not be reintroduced. Any shell replacement in helper 2's worktree must take the name through a variable or standard input, never by building a string that is then interpreted.
- Eight parallel worktrees each running `bun run test:electron` will contend for machine resources. The agent should stagger the Electron runs rather than starting all of them at once, or run them one worktree at a time at the end of Step 3.
