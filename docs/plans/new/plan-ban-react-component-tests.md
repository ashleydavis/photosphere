# Ban React Component/Hook Tests, Factor Significant Logic Into lib/

## Overview
The project rules currently allow unit-testing React components, contexts, and hooks, and there is one such test in the tree (`packages/mobile-frontend/src/test/use-mobile-asset-server.test.tsx`) that renders a hook with `@testing-library/react`. We want to forbid that style of test. React components, contexts, and hooks should be thin shells. Only significant logic is worth extracting into a plain `lib/` function and unit-testing; trivial one-liners (such as a URL string builder) should stay inline in the component and remain untested rather than being extracted just to gain a test. This plan adds the rule to the project instructions, deletes the one existing React hook test, and exercises the rule on that hook: its only logic is trivial URL construction, so it is left inline and untested (no extraction). It confirms no React-component-testing dependency is declared in any manifest. It explicitly does NOT remove `jest-environment-jsdom`, which is still needed by non-React DOM tests (`test-driver.test.ts`, `test-driver-ws.test.ts`).

## Issues
<!-- Leave empty — populated later by plan:check -->

## Steps

1. **Add the rule to `CLAUDE.md`.** Edit `/CLAUDE.md` (project root). In the `## Code Style` section, immediately after `- Use \`test(\` not \`it(\` in Jest test files.`, add a bullet that:
   - Forbids unit-testing React components, contexts, and hooks, and forbids `@testing-library/react` / `renderHook` / any component or hook rendering in tests.
   - States a React component/context/hook must be a thin shell.
   - Clarifies that only significant (non-trivial) logic is worth extracting into a plain function under a `lib/` directory and unit-testing, and that trivial logic (for example a one-line string or URL builder) must be left inline in the component and untested rather than extracted just to gain a test.
   Also amend the `## Restrictions` bullet `- Add new tests for new code...` by appending an exception clause noting React components, contexts, and hooks are not unit tested (extract any significant logic into a `lib/` function and test that instead).
   - Requirement: wording uses no em dashes, follows the existing bullet style, and introduces no machine-specific paths.

2. **Delete the React hook test.** Remove `packages/mobile-frontend/src/test/use-mobile-asset-server.test.tsx`. This is the only React component/hook test in the working tree.

3. **Exercise the rule on `useMobileAssetServer`.** Inspect `packages/mobile-frontend/src/lib/use-mobile-asset-server.ts`. Its only logic is trivial URL construction (`http://localhost:3001` default and `` `http://localhost:${port}` `` on ready). Per the clarified rule this is NOT significant enough to extract. Leave the hook exactly as its original thin shell (inline `DEFAULT_REST_API_URL` constant and inline template literal); do not create a `lib/` helper and do not add a unit test for it.
   - Requirement: the hook still compiles and contains no `@testing-library`/`renderHook` usage anywhere in the package.

4. **Confirm no React-component-testing support remains declared.** Run a `Bash` grep across all manifests (`package.json`, `packages/*/package.json`, `apps/*/package.json`) for `@testing-library`. Expected: no matches (these are phantom/hoisted, declared nowhere). If any manifest declares `@testing-library/react` or `@testing-library/jest-dom`, remove that dependency line. Do NOT touch `jest-environment-jsdom` entries in `packages/user-interface/package.json`, `packages/node-utils/package.json`, or `packages/utils/package.json` — they are required by non-React DOM tests.
   - Requirement: `grep -rn "@testing-library\|renderHook" packages apps --include="*.ts" --include="*.tsx"` (excluding `node_modules`) returns no matches.

## Unit Tests

- None added. The removed hook is a React hook whose only logic is trivial URL construction; per the clarified rule it is neither extracted nor unit tested.

## Smoke Tests

- No new smoke test. There is no automated iOS/Android e2e harness in the repo (`bun run test:cli` and `bun run test:electron` cover CLI and Electron only). The hook is thin lifecycle wiring (start the asset-server task on mount, swap the URL when `asset-server-ready` arrives, shut the queue down on unmount) with no branching logic. This is called out explicitly rather than silently skipped.
- Existing `bun run test:electron` and `bun run test:cli` must continue to pass unchanged.

## Verify

- `bun run compile` completes with no TypeScript errors.
- `bun run test` no longer runs `use-mobile-asset-server.test.tsx` and passes for the packages this change touches (`mobile-frontend`).
- `grep -rn "@testing-library\|renderHook" packages apps --include="*.ts" --include="*.tsx"` (excluding `node_modules`) returns no matches.
- `/CLAUDE.md` contains the new prohibition bullet (with the significant-logic-only clarification) and the amended "Add new tests for new code" exception.

## Notes

- Scope of "the rules": only the project-root `/CLAUDE.md` (checked into the repo) is edited. The user's private global `~/.claude/CLAUDE.md` is out of scope and must not be modified.
- This plan deliberately does NOT extract the hook's URL logic. An earlier draft created a `lib/asset-server-url.ts` helper plus a unit test; that was reverted because the logic is a one-line string builder, and testing it adds a test and an indirection without real value. Leaving it inline is the intended demonstration of the clarified rule.
- `@testing-library/react` (v14.3.1) and `@testing-library/jest-dom` are present in root `node_modules` but declared in no manifest, so deleting the one importing test is sufficient; there is no dependency to uninstall.
- `jest-environment-jsdom` stays. `packages/user-interface/src/test/lib/test-driver.test.ts` and `test-driver-ws.test.ts` use `@jest-environment jsdom` to drive a DOM-query-based test driver (`document.body.innerHTML`, `querySelector`), which is not React component testing and is unaffected.
- `mobile-frontend/jest.config.js` uses `testEnvironment: 'node'`; after deleting the only jsdom-docblock test in that package, the config needs no change.
