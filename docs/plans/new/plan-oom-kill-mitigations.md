# Options for stopping out-of-memory kills during test runs (none approved)

## Overview

`systemd-oomd` has killed processes on this development machine ten times since 17 July, nine of those in a terminal scope, once taking 354 processes and the whole Android emulator pool with it and failing a test run that was otherwise passing. Two other plans exist for this, neither implemented: `docs/plans/new/plan-emulator-oom-isolation.md`, which would stop an unrelated kill taking the emulator pool down but reduces no memory, and `docs/plans/new/plan-fix-leaked-test-processes.md`, which would remove the waste that pushed an ordinary run over the edge. This plan collects everything else that could be done, so the options are written down and comparable rather than being invented one at a time in the middle of a failure. **Nothing in this plan is approved.** Every option below is a proposal only. The implementing agent must not action any of them without the human explicitly approving that specific option, by name, in the message the agent is acting on. Approval of one option is not approval of another, and an approval given in an earlier session does not carry forward. Several options change machine configuration rather than repository code, and one would require editing a file the repository freezes, so each option states plainly what it touches and what it costs.

## Issues

## Steps

**Step 0 is a gate, not work.** Before any other step, the agent must confirm which options the human has approved by name. With no explicit approval, the agent implements nothing from this plan, reports the options, and stops. If the human approves some options and not others, the agent implements only the approved ones and leaves the rest in place in this file for later.

The measurements this plan is built on, taken while five emulators were running and no test suite was active: RAM 62.2 GiB total with 27.4 GiB used; swap 66.0 GiB total with 38.8 GiB used; five `qemu-system-x86` processes at 3.0 to 3.7 GiB resident each. `oomctl` reports that the only rule in play is memory pressure on the user session at a 50% limit over 20 seconds, and that no cgroup is registered for swap monitoring, so the documented 90% swap rule never fires here.

1. **Raise the `systemd-oomd` pressure limit (machine configuration, no repository change).** The kill threshold on `user@<uid>.service` is 50% pressure sustained for 20 seconds, set by the distribution in `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf`. Raising it to 80% means short stalls stop killing things. If approved, the agent creates `/etc/systemd/system/user@.service.d/50-oomd-pressure.conf` containing a `[Service]` section with `ManagedOOMMemoryPressureLimit=80%`, runs `systemctl daemon-reload`, and applies it to the running session with `systemctl set-property`. Both need root, so the agent must ask before running them rather than assuming sudo. The agent must not edit the file under `/usr/lib`, which a systemd update would overwrite. Verification is `oomctl` reporting the new limit. **Cost:** the machine will thrash for longer before anything is killed, so a genuinely stuck run degrades the desktop further before it resolves. **Nothing here is testable by a unit test**, and the plan must not pretend otherwise: the check is the `oomctl` output and the absence of kills in `journalctl --user` over subsequent runs.

2. **Run the test suites under a memory ceiling (new repository script).** If approved, the agent adds `scripts/run-capped.sh`, which wraps a command in a transient systemd scope carrying a memory ceiling, so the test run absorbs the consequence of its own appetite rather than the whole session being killed. It must accept the ceiling through an environment variable with a documented default, must fall back to running the command unchanged where systemd is unavailable (macOS), and must pass the command's exit status through unaltered. The agent adds a `test:capped` script to the root `package.json` rather than changing what `test:everything` does. Split it into a function that prints the argv one argument per line without running anything, and a caller that executes it, so the command can be asserted by a test without a systemd scope being created. **Cost:** `MemoryHigh` throttles rather than kills, and a throttled run still stalls, and stalls are what the pressure rule measures, so this reduces the risk without removing it. `MemoryMax` kills the run outright at the ceiling, which trades an unpredictable victim for a predictable one. The agent must ask which of the two the human wants; it must not pick one.

3. **Reduce the emulator pool's memory (repository change plus AVD configuration).** `PHOTOSPHERE_EMULATOR_COUNT` in `apps/android-frontend/scripts/emulator.sh` defaults to 5, and each emulator is 3.0 to 3.7 GiB resident against the 2048 MiB its AVD configures, so the pool is 16 to 19 GiB. If approved, the agent lowers that default to a number the human names and updates `apps/android-frontend/scripts/emulator.md` and `apps/android-frontend/CLAUDE.md` to match. Lowering the RAM in each AVD's `config.ini` is a second, separate option that the agent must not take without its own approval, because those files live outside the repository and are shared with the human's hand-testing emulator. **Cost:** fewer emulators means the Android suite takes proportionally longer, since `run.sh` splits tests across whatever is available. This is the option with the largest, most predictable saving and the most visible daily cost.

4. **Cap how many suites run at once (blocked by a frozen file).** `scripts/test-everything-parallel.sh` runs `compile`, `test`, `test:cli`, `test:electron`, `test:and:unit` and `test:and` as parallel lanes, with only the two Android lanes serialised against each other, and that is the single largest concurrent memory demand on the machine. The obvious mitigation is to serialise the heaviest lanes or bound the number in flight. **The agent must not edit that file.** `CLAUDE.md` freezes it along with `.githooks/pre-commit` and `scripts/install-hooks.sh`, on the grounds that they carry no automated tests and a broken gate fails silently. If the human wants this, the agent's action is to describe the exact change and hand it to the human to make, or to be told explicitly in that same message that the freeze is lifted for this edit. Recording the option here is not permission to take it.

5. **Reduce the Electron smoke suite's concurrency (repository change).** `apps/desktop/smoke-tests.sh` runs tests in parallel batches of 2 by default, each batch launching an Electron app and an `Xvfb` server, and the share tests launch two apps each. If approved, the agent makes the batch size read an environment variable with the current default of 2 preserved, so a memory-constrained run can drop it to 1 without a code change. **Cost:** none at the default. This is the cheapest option in the plan and the smallest saving.

6. **Refuse to start a suite when the machine is already short (new repository script).** If approved, the agent adds `check_memory_headroom` to a shared shell library and calls it at the start of `apps/desktop/smoke-tests.sh`, `apps/cli/smoke-tests.sh` and `apps/smoke-tests/run.sh`. It reads available memory and free swap, compares them against a documented threshold, and fails the suite immediately with a message naming what is holding memory, rather than starting a run that will be killed halfway through. It must be a warning by default and only fail when an environment variable asks it to, because a hard refusal that fires wrongly is worse than the kill it prevents. **Cost:** another thing that can wrongly block a run. The failure mode is visible and the message tells you how to override it, which is why it is worth considering.

7. **Record what each suite actually costs (new repository script).** No option above can be chosen well without knowing which suite is the expensive one, and nobody has measured it. If approved, the agent adds `scripts/measure-suite-memory.sh`, which runs a named suite while sampling total resident memory and swap at a fixed interval and writes a peak-usage summary to a gitignored file. **Cost:** a long run per measurement, and the numbers are only valid for this machine. This is the option that makes the others decidable, so it is the one worth doing first if any are.

8. **Reduce reliance on swap (machine configuration, no repository change).** 38.8 GiB of 66 GiB swap is in use with the machine otherwise idle, and swap thrashing is what generates the pressure that triggers the kills. Options are lowering `vm.swappiness` so the kernel prefers reclaiming page cache, or adding a compressed RAM swap device ahead of the swap file. If approved, the agent applies exactly the one the human names, as a file under `/etc/sysctl.d/`, and nothing else. **The agent must not enlarge the swap file:** more swap means a longer stall before anything gives, which makes the desktop worse without preventing the kill. **Nothing here is testable by a unit test**; verification is the swap figures and the absence of kills over subsequent runs.

9. **Add memory to the machine (no code, no configuration).** 62 GiB of RAM against a peak demand of roughly 16 to 19 GiB of emulators plus several GiB per concurrent suite plus a browser, an editor and Gradle is tight, and it is the only option that removes the swap thrashing at its root rather than managing it. Recorded here for completeness because it is a real answer to the question, not because an agent can action it.

10. **Document whichever options are approved.** After implementing an approved option, the agent adds a short section to `docs/testing/README.md` naming what changed, how to override it, and how to undo it. Options 1 and 8 change the machine rather than the repository, so their documentation must state that the change does not travel with a checkout and will not exist on any other machine or in CI.

## Unit Tests

Only the repository-code options have anything a unit test can reach. Each list applies only if that option is approved.

For option 2, in `scripts/run-capped.test.sh`, following the pattern of `apps/smoke-tests/timeout.test.sh`:

- The argv builder prints the systemd form, including the chosen memory property and the wrapped command, when systemd scopes are available.
- The argv builder prints the bare command, unchanged, when they are not, which is the macOS path.
- The argv builder passes the wrapped command's own arguments through untouched, including arguments containing spaces.
- The ceiling comes from the environment variable when it is set, and from the documented default when it is not.
- The wrapper returns the wrapped command's exit status for both a success and a named non-zero status.

For option 5, in the existing desktop smoke-test harness tests:

- The batch size is 2 when the environment variable is unset, matching today's behaviour exactly.
- The batch size is the environment variable's value when it is set.
- A non-numeric or zero value is rejected with a clear message rather than silently running everything at once.

For option 6, in a test for the shared library:

- `check_memory_headroom` passes when available memory and free swap are above the threshold, with both values injected rather than read from the live machine.
- It fails when available memory is below the threshold.
- It fails when free swap is below the threshold even though memory is fine, which is the state that precedes the kills seen here.
- It warns and returns success by default, and only returns failure when the strict environment variable is set.

For option 7:

- The sampler's parsing function turns a captured `free` output line into the numbers it reports, for a normal reading and for a machine with no swap configured.
- The peak calculation returns the largest sample from a fixed list, and returns nothing rather than zero for an empty list.

## Smoke Tests

- For option 2: a case in `scripts/run-capped.test.sh` that runs a short stub command through the real wrapper and asserts the stub's output and exit status arrive unchanged, and that the memory property was accepted by systemd rather than rejected. It must skip with a printed `SKIP` line where there is no usable systemd user session, so the case is a no-op on macOS and in containers rather than a failure.
- For option 5: a full `bun run test:electron` with the batch size set to 1, asserting the suite still passes and that no more than one Electron app is alive at any sample point.
- For option 6: a case that runs the check with injected values below the threshold in strict mode and asserts the suite exits before starting a single test.
- For option 7: a case that measures a short stub command and asserts the summary file is written and contains a peak greater than zero.
- Options 1, 8 and 9 have no smoke test, because they change the machine and not the code. This must be stated in their documentation rather than covered by an empty test.

## Verify

- `bash -n` passes on every script added or edited.
- Every test listed above for an approved option passes with no failures.
- `bun run compile` clean and `bun run test` passing.
- `bun run test:cli`, `bun run test:electron` and `bun run test:and` all pass, proving no approved option changed what the suites do by default.
- For any option that adds an environment variable, the suites behave byte-for-byte as they do today when it is unset. This is the check that keeps the whole plan opt-in.
- For options 1 and 8, `oomctl` and the swap figures show the intended values, and `journalctl --user` shows no new `systemd-oomd killed` line across a subsequent full test run.
- No change to `scripts/test-everything-parallel.sh`, `.githooks/pre-commit` or `scripts/install-hooks.sh`.
- The step 10 documentation names only commands that exist, and every relative link added resolves to a file that exists.

## Notes

- **Nothing here is approved.** This file is a menu. The agent's default action on reading it is to present the options and stop. Implementing an option because it appears in a plan is exactly the mistake this plan exists to avoid.
- **Approval must be per option and current.** Approving option 3 is not approval of option 4. An approval in an earlier session is not an approval now. Where an option has a sub-decision, such as the throttle-or-kill choice in option 2 or which emulator count in option 3, the agent must ask rather than choose.
- **Two options change the machine, not the repository.** Options 1 and 8 do not travel with a checkout, will not exist in CI, and will not exist on another developer's machine. Anyone reasoning later about why the machine behaves differently from CI needs them written down, which is what step 10 is for.
- **One option is blocked by a repository rule.** Option 4 needs an edit to a frozen file. The freeze exists because a broken test gate fails silently, and that reasoning does not weaken because the motivation is memory. Recording the option is not permission.
- **Measure before choosing.** Option 7 is the only one that produces evidence, and every other option is currently being argued from a single incident and one set of idle-machine readings. If only one option is approved, it should be that one.
- **What other plans cover, and this one deliberately does not repeat.** `plan-emulator-oom-isolation.md` would stop an unrelated kill taking the emulator pool with it. `plan-fix-leaked-test-processes.md` would remove roughly 8.8 GiB of pure waste seen at the time of the largest kill. Both are unimplemented plans in `docs/plans/new/`, and neither reduces the memory a healthy run needs, which is what this plan is about.
- **The largest saving and the largest cost are the same option.** Option 3 saves 6 to 7 GiB by dropping the pool from five emulators to three, and makes every Android suite run noticeably longer, every day. That trade is the human's to make, not the agent's.
