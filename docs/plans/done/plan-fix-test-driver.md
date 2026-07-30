# Fix the smoke-test driver so tests actually drive the app

## Overview

`packages/user-interface/src/lib/test-driver.ts` is the shared DOM driver every smoke test runs through, on Electron, Android and iOS. Two faults in it cause tests to **pass while testing nothing**. This is worse than a failing test: a failing test tells you something, a test that clicks the wrong element and then asserts on a screen that never changed tells you the opposite of the truth.

Both faults come from the same root cause: the driver assumes the element carrying `data-id` is the element to act on. For MUI Joy components that is often false. Joy puts the `data-id` on a wrapper `<span>` or `<div>` and the real form control inside it.

This plan fixes the driver. It changes no product behaviour and no test assertions. It is deliberately small so the diff can be read in one sitting.

## Why this is worth doing (read this before deleting the plan)

**Fault 1: clicking a radio or checkbox does nothing at all.**

`doClick` (around line 188) resolves the element by `data-id` and calls `element.click()`. In `packages/user-interface/src/components/replicate-database-dialog.tsx` the `data-id` values `replicate-mode-partial` and `replicate-mode-full` are on Joy `<Radio>` components (lines 283 to 298), which render a wrapper carrying the attribute with `<input type="radio">` nested inside. Clicking the wrapper does not select the radio.

Consequence: the replication smoke test selects "Full", the mode stays on "Partial", the test then asserts on a partial replication and passes. **The suite reports that it covers both full and partial replication. It has only ever tested partial.** Nothing in the output hints at this: the click logs success, because the driver found an element and clicked it.

**Fault 2: reading a container returns a nested control's value instead of its text.**

`getValue` (around line 349) reads `element.value`, then falls back to `element.querySelector('input')?.value`, then to `textContent`. For a panel or a row containing a Joy `<Switch>`, `querySelector('input')` finds the switch's hidden checkbox, whose `.value` is the string `"on"` by default. `"on"` is truthy, so `getValue` returns `"on"` and never reaches `textContent`.

Consequence: any test doing `wait_for_value` on a container that happens to contain a switch waits for text that can never be returned, and times out. That is at least a wasted timeout per affected test, and it forces whoever hits it to weaken the assertion to something that does pass, which spreads the damage.

**Why the driver and not the components:** the components are correct. Putting `data-id` on the Joy component is the documented way to label it, and the same attributes are used by the stories browser. The driver is the thing making a wrong assumption about what it received, so the driver is where the fix belongs. Changing 20 components to hoist `data-id` onto inner inputs would be a much larger diff, would fight the component library, and would break the moment someone adds a new one.

**Why now:** every future smoke test is built on this driver. Any parity or coverage work done before this is fixed produces results that cannot be trusted, because a passing test may be a test that clicked nothing.

## Issues

## Steps

Each step must leave `bun run compile` clean and `bun run test` passing before it is done.

### Step 1: Add a helper that resolves the real target of a click

In `packages/user-interface/src/lib/test-driver.ts`, add two small exported functions above `doClick`:

- `isToggleInput(element: HTMLElement): boolean` — true when the element is an `<input>` whose `type` is `radio` or `checkbox`.
- `clickTarget(element: HTMLElement): HTMLElement` — returns the element to click. If the element is itself clickable (a button, link, or toggle input), returns it unchanged. Otherwise, if it contains exactly one nested radio or checkbox input, returns that input. Otherwise returns the element unchanged.

Requirements:

- The fallback must be conservative. Returning the element unchanged is always the safe answer, so anything ambiguous (no nested toggle, or more than one) returns the original.
- No behaviour change for elements that are already the right target, which is the majority. This keeps the blast radius small.

### Step 2: Use it in `doClick`

Change `doClick` to call `clickTarget` on the resolved element before calling `.click()`. Extend the existing log line to report when the target was redirected to a nested control, so a future failure shows what was actually clicked rather than what was asked for.

Do not change `doLongPressClick`, `doType` or any other command in this step. They have their own resolution needs and mixing them in makes the diff harder to check.

### Step 3: Fix `getValue` to prefer the element's own value, then its text

Rewrite `getValue` so the order of preference is:

1. If the element is itself a form control (`input`, `textarea`, `select`), return its own value. This is the unambiguous case.
2. Otherwise, if the element has non-empty text content, return that. A container's text is what a test asking for its value means.
3. Otherwise, fall back to a nested input's value, preserving the existing Joy `<Input>` case where the wrapper carries the `data-id` and holds no text of its own.

The change that matters is putting text content ahead of the nested-input fallback, so a container containing a switch reports its text rather than the string `"on"`.

Keep the existing "visible one" behaviour that `findElement` provides. This step must not change which element is found, only what is read from it.

### Step 4: Confirm the faults are actually gone

- Add the unit tests below and confirm each fails against the current code before the fix and passes after. A test that passes both before and after is not testing the fault.
- Run the replication smoke test on Electron and confirm the full-replication case now genuinely runs in full mode, by asserting on something only a full replication produces (asset files present at the destination, not just the database).

## Unit Tests

In `packages/user-interface/src/test/lib/test-driver.test.ts` (create if absent), against a jsdom DOM built in the test:

- `isToggleInput`: true for `input[type=radio]` and `input[type=checkbox]`; false for `input[type=text]`, a button, and a div.
- `clickTarget`: returns a button unchanged; returns a bare radio input unchanged; returns the nested radio when given a wrapper containing exactly one; returns the wrapper unchanged when it contains no toggle; returns the wrapper unchanged when it contains two toggles.
- `getValue`: returns an input's own value; returns a container's text content ahead of a nested checkbox's `"on"`; returns a nested input's value when the wrapper has no text (the Joy `Input` case); returns an empty string when the element is missing.

These are plain functions on a DOM, not React components, so they are unit tested rather than covered only end to end.

## Smoke Tests

No new smoke tests, and no changes to existing assertions in this plan.

The existing replication test is the acceptance check: after step 2 it must select Full mode for real. If that test does not currently assert anything that distinguishes full from partial, note it and raise it separately, because that is a test-coverage fault rather than a driver fault and fixing both in one change makes the diff unreadable.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:all` passes.
- `bun run test:and` passes.
- Every new unit test fails against the pre-fix driver and passes after. Record this; it is the only proof the fix addresses the stated faults.
- `git diff --stat` shows changes limited to `packages/user-interface/src/lib/test-driver.ts` and its test file. Any product file in the diff means the plan was exceeded.

## Notes

- **Fix the cause, not the symptom.** Do not work around either fault by changing a smoke test to click a different `data-id`, by adding `data-id` attributes to inner inputs, or by weakening an assertion. Those hide the fault and it returns in the next test written.
- The conservative fallback in `clickTarget` is deliberate. A driver that guesses aggressively fails in a new and confusing way; one that returns the original element behaves exactly as it does today.
- If step 4 shows the replication test still cannot tell full from partial apart, that is a separate finding. Record it, do not fix it here.
