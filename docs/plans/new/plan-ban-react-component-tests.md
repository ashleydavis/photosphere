# Ban React Component/Hook Tests, Factor Logic Into lib/

## Overview
The project rules currently allow unit-testing React components, contexts, and hooks, and there is one such test in the tree (`packages/mobile-frontend/src/test/use-mobile-asset-server.test.tsx`) that renders a hook with `@testing-library/react`. We want to forbid that style of test. React components, contexts, and hooks should be thin shells with no testable logic. Any logic worth testing should be factored out into a plain function under a `lib/` directory and unit-tested there. This plan adds the rule to the project instructions, refactors the one existing offender to move its testable logic into a plain lib function with its own unit test, and deletes the React hook test. It confirms that no React-component-testing dependency is declared in any manifest so there is no support left to encourage the practice. It explicitly does NOT remove `jest-environment-jsdom`, which is still needed by non-React DOM tests (`test-driver.test.ts`, `test-driver-ws.test.ts`).

## Issues
<!-- Leave empty — populated later by plan:check -->

## Steps

1. **Add the rule to `CLAUDE.md`.** Edit `/CLAUDE.md` (project root). In the `## Code Style` section, immediately after the existing testing bullets (`- Tests should go under the directory src/test in each package.` / `- Use \`test(\` not \`it(\` in Jest test files.`), add a new bullet:
   - "Do not write unit tests for React components, contexts, or hooks. Do not use `@testing-library/react`, `renderHook`, or any component/hook rendering in tests. A React component/context/hook must be a thin shell with no testable logic; if it contains logic worth testing, factor that logic out into a plain function under a `lib/` directory and unit-test the plain function instead."
   Also amend the `## Restrictions` bullet `- Add new tests for new code. Every function that is new, that you edit, or that the user asks you about should have unit tests.` by appending an exception clause: "The exception is React components, contexts, and hooks, which are not unit tested (extract any testable logic into a `lib/` function and test that instead)." Make both edits to `/CLAUDE.md` in a single `Edit`/`Write` pass (one write per file).
   - Requirement: wording uses no em dashes, follows the existing bullet style, and does not introduce machine-specific paths.

2. **Create the extracted URL helper.** Add new file `packages/mobile-frontend/src/lib/asset-server-url.ts` containing the pure logic currently inline in the hook:
   - Exported constant `DEFAULT_ASSET_SERVER_REST_API_URL: string = "http://localhost:3001"` with a `//` comment block explaining it is the restApiUrl used before the asset-server task reports its bound port.
   - Exported function `buildAssetServerRestApiUrl(port: number): string` that returns `` `http://localhost:${port}` ``, with a `//` comment block above it describing intent.
   - Requirement: file compiles under `tsc --noEmit`; comment blocks on both globals per project style.

3. **Refactor the hook to use the helper.** Edit `packages/mobile-frontend/src/lib/use-mobile-asset-server.ts`:
   - Remove the local `DEFAULT_REST_API_URL` constant (lines defining it) and its comment block.
   - Import `DEFAULT_ASSET_SERVER_REST_API_URL` and `buildAssetServerRestApiUrl` from `./asset-server-url`.
   - Replace `useState<string>(DEFAULT_REST_API_URL)` with `useState<string>(DEFAULT_ASSET_SERVER_REST_API_URL)`.
   - Replace the `setRestApiUrl(\`http://localhost:${message.port}\`)` call body with `setRestApiUrl(buildAssetServerRestApiUrl(message.port))`.
   - Leave all React lifecycle wiring (`useEffect`, `TaskQueue` construction, `onTaskMessage`, `addTask`, cleanup/`shutdown`) unchanged.
   - Requirement: the hook now contains no inline URL-construction literal; it compiles.

4. **Delete the React hook test.** Remove the file `packages/mobile-frontend/src/test/use-mobile-asset-server.test.tsx` (via `Bash` `git rm` is not required; a plain file delete is fine since staging is out of scope). This is the only React component/hook test in the working tree.

5. **Add the unit test for the extracted logic.** Create `packages/mobile-frontend/src/test/asset-server-url.test.ts` (node environment, no `@jest-environment jsdom`, no React import) testing `buildAssetServerRestApiUrl` and `DEFAULT_ASSET_SERVER_REST_API_URL`. See Unit Tests section for cases.
   - Requirement: uses `test(` not `it(`, 4-space indentation, no rendering, passes under `bun run test`.

6. **Confirm no React-component-testing support remains declared.** Run a `Bash` grep across all manifests (`package.json`, `packages/*/package.json`, `apps/*/package.json`) for `@testing-library`. Expected result: no matches (these packages are phantom/hoisted and declared nowhere). If any manifest declares `@testing-library/react` or `@testing-library/jest-dom`, remove that dependency line from the manifest. Do NOT touch `jest-environment-jsdom` entries in `packages/user-interface/package.json`, `packages/node-utils/package.json`, or `packages/utils/package.json` — they are required by non-React DOM tests.
   - Requirement: after this step, `grep -rn "@testing-library" packages apps --include="*.ts" --include="*.tsx"` returns no source references outside `node_modules`.

## Unit Tests

- `packages/mobile-frontend/src/test/asset-server-url.test.ts` (new):
  - `buildAssetServerRestApiUrl(54321)` returns `"http://localhost:54321"`.
  - `buildAssetServerRestApiUrl(0)` returns `"http://localhost:0"` (documents the OS-assigned-port placeholder behaviour).
  - `buildAssetServerRestApiUrl(3001)` returns `"http://localhost:3001"`.
  - `DEFAULT_ASSET_SERVER_REST_API_URL` equals `"http://localhost:3001"`.
- No unit test is added or kept for `useMobileAssetServer` (it is a React hook; per the new rule its lifecycle wiring is not unit tested and its only extractable logic now lives in `asset-server-url.ts`).

## Smoke Tests

- There is no automated iOS/Android e2e harness in the repo (`bun run test:cli` and `bun run test:electron` cover CLI and Electron only; the mobile frontends under `apps/android-frontend` / `apps/ios-frontend` have no smoke-test runner). The hook's remaining responsibility after refactor is thin lifecycle wiring (start the asset-server task on mount, swap the URL when `asset-server-ready` arrives, shut the queue down on unmount) with no branching logic, so no new smoke test is added. This is called out explicitly rather than silently skipped.
- Existing `bun run test:electron` and `bun run test:cli` must continue to pass unchanged (they do not exercise the mobile hook, but they confirm the rule/manifest changes did not break the build).

## Verify

- `bun run compile` completes with no TypeScript errors (confirms the new lib file, the refactored hook, and all consumers in `apps/android-frontend/src/app.tsx` and `apps/ios-frontend/src/app.tsx` still type-check).
- `bun run test` passes, including the new `asset-server-url.test.ts`, and no longer runs `use-mobile-asset-server.test.tsx`.
- `bun run test:electron` passes.
- `bun run test:cli` passes.
- `grep -rn "@testing-library" packages apps --include="*.ts" --include="*.tsx"` (excluding `node_modules`) returns no matches.
- `grep -rn "renderHook" packages apps --include="*.ts" --include="*.tsx"` (excluding `node_modules`) returns no matches.
- `/CLAUDE.md` contains the new prohibition bullet and the amended "Add new tests for new code" exception.

## Notes

- Scope of "the rules": only the project-root `/CLAUDE.md` (checked into the repo) is edited. The user's private global `~/.claude/CLAUDE.md` is out of scope and must not be modified.
- `@testing-library/react` (v14.3.1) and `@testing-library/jest-dom` are present in root `node_modules` but declared in no manifest, so removing the one test that imports them is sufficient; there is no dependency to uninstall. Step 6 verifies this rather than assuming it.
- `jest-environment-jsdom` stays. `packages/user-interface/src/test/lib/test-driver.test.ts` and `test-driver-ws.test.ts` use `@jest-environment jsdom` to drive a DOM-query-based test driver (`document.body.innerHTML`, `querySelector`), which is not React component testing and is unaffected by this change.
- `mobile-frontend/jest.config.js` uses `testEnvironment: 'node'`; after deleting the only jsdom-docblock test in that package, the config needs no change.
- The extracted logic is deliberately small (URL construction). That is the point of the rule: even thin logic belongs in a testable plain function rather than being asserted through a rendered hook.
