---
description: Step the human through the manual e2e testing checklist one test and one command at a time, ticking tests off and recording notes as they go.
---

# Step through the manual testing checklist

Take the human through `docs/testing/e2e/CHECKLIST.md`, one test at a time and one command at a time. The human runs every command unless they reply "y". You give the command, say what to expect, and wait.

## Before you start

- Read `docs/testing/e2e/CHECKLIST.md` and `docs/testing/e2e/CHECKLIST-NOTES.md`.
- If arguments were given (`$ARGUMENTS`), start at the section or test they name. Otherwise start at the first unticked test.
- Take the human only through untested tests, marked `- [ ]`. Skip tests marked `- [x]` (passed) or `- [-]` (failed), unless the arguments ask for them.

## For each test

1. Read the test's markdown file, linked from the checklist. If it is not already laid out as `## Prep` (prerequisites and setup or cleanup commands, in one code block), `## Test` (the commands being tested) and `## Check` (the commands that check the results against what was expected), rewrite it that way before you start the test. Keep every command, every expectation and the order of the steps; only the layout and wording change. Fix anything else in it that does not make sense as you go.
2. Say which test it is, its position in its section, and what it checks, in one line.
3. If `CHECKLIST-NOTES.md` has **revist and confirm** notes under this test, list them and ask the human, for each one, whether it still holds. Once they answer, take the marker off a note that still holds and delete a note they say no longer holds.
4. Give the prep first as one step: the prerequisites and every step before the first one under test that only sets up or cleans up (such as changing directory or removing a previous run's files), all commands together in one code block in the order the test writes them. Then give each remaining step, ONE command per message:
    - The step number and title.
    - The command, exactly as the test file writes it, in a code block.
    - What to expect, from the test file.
    - The menu, as a bullet list, one option per bullet:
        - `d` done
        - `y` you run it
        - `s` show again
        - `a` approve test
        - `f` fail test
        - `Note: xxx` add a note
    - Then stop and wait for the human to say it is done or to say what happened. "d" means done: the step went as expected. "Note: xxx" means add xxx as a note under the current test in `CHECKLIST-NOTES.md`, word for word, then carry on with the same step. "s" means show the current step again. "a" means the current test is approved: tick it (`- [x]`) and move to the next test. "f" means the current test failed: mark it `- [-]` and move to the next test. If the human has not already given notes for the failure and the failure is plain from the session, write the notes yourself under that test, saying which step failed and what happened; otherwise expect the human to follow up with notes. "y" means run the current step's command yourself, exactly as shown, from the directory the test says, then show the human the command's full output in a code block, with a `>>-` line before the output and a `<<-` line after it inside the block (always for a `## Test` command; for Prep and Check commands, the lines that show the result), then two labelled lists, **Result:** (what happened, one bullet per thing the step checks) and **Expected:** (the test file's expectations, word for word), then one line saying whether they match, naming each part that does not. Start that line with 🟢 when they match and 🔴 when they do not, for example `🟢 **Match:** yes` or `🔴 **Match:** no.` Show these for every step you run, UI steps included. Move on as for "d" only when they match; otherwise wait for the human.
    - Whenever a message is about anything other than moving on, end it by showing the current step again in full: the step number and title, the command and what to expect.
5. When the human reports a result that differs from what was expected, record it as a note under that test in `CHECKLIST-NOTES.md`, in the human's words. Then carry on with the next step unless the human says otherwise.
6. When every step has passed, tick the test in `CHECKLIST.md` (`- [x]`). When a step failed, mark it `- [-]` and say which step failed in the note. "a" and "f" from the human decide this whenever they are given.

## Driving the desktop app yourself

When the human asks you to run desktop steps yourself, drive a test-hooks build of the app through its control connection, the way `apps/photosphere-smoke-tests` does.

- Build it into the project's `tmp/`: `bun run --filter=ziggy bundle:ui`, then `zig build photosphere-linux -Dtest-hooks=true -p tmp/desktop-hooks/test`. Rebuild after any UI change.
- Start it in the background with the test's own export block plus the variables `photosphere_platform_start` in `apps/photosphere-smoke-tests/lib/linux.sh` sets (`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, `PHOTOSPHERE_TEST_MODE=1`, `ZIGGY_TEST_MODE=1`, `ZIGGY_TEST_PORT_FILE`). When you are taking the human through a test, including a step they answer with "y", start it with a visible window. Only when you run tests on your own, without the human following along, wrap it in `xvfb-run` for a hidden window.
- Send commands the way `control_command`, `send_command` and `read_value` in `apps/photosphere-smoke-tests/lib/common.sh` do: `click`, `type`, `navigate`, `menu`, `pick-answer`, `get-value`, `long-press`, `long-press-click`, `screenshot` and `quit`. Elements are found only by `data-id`, in `packages/user-interface/src`.
- Queue `pick-answer` before clicking the button that opens a picker or a save dialog. Open an asset with `long-press-click` on `gallery-thumb`, and select one with `long-press`, since there is no hover command.
- Exporting `XDG_DATA_HOME` also moves mise's data folder, so set `MISE_DATA_DIR` back to the normal one for your own `mise exec` commands.
- Quit every instance as soon as its test is done, and check that none is left running. Use at most one subagent for a run of many tests.
- Leave a step that needs a human to judge (such as whether a video plays) open in a visible window for the human, at the end of the run.

## Rules

- This is testing only. We are not fixing problems unless the human decides to do that.
- **Do not skip steps.** Run every step in the order the test writes it. Do not reorder, defer or merge steps, or decide one is not worth running. Only the human can ask for that. The one exception, which the human asked for, is the prep step in step 4.
- **Do not skip prep.** Every command in a test's Prep goes into the prep step, read from every code block in the Prep section, and every one is run. A skipped prep command makes a test fail for no reason.
- When a step fails, check that every prep command ran before calling it a failure.
- Notes go only in `CHECKLIST-NOTES.md`, never in `CHECKLIST.md`. A note says what happened to the app or the test, never who did or decided something: no mention of "the human". Use the same `##` section, `###` group and `####` test name headings as the checklist, adding a heading when it is missing.
- Commands given to the human never start with `mise exec --`.
- Keep every message short: the step, the command, what to expect. No waffle.

## At the end of a section

- Say how many tests passed and how many failed, and name the failed ones.
