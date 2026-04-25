# Plan: "Update Available" Notification

## Context

Photosphere has no update mechanism. Users on desktop (Electron) or self-hosted web must manually check for new releases. The goal is a lightweight "update available" notification that tells users when a newer version exists on GitHub — without the complexity of auto-download/install (no code signing infrastructure, no update server, no electron-updater).

The approach: on app startup, silently fetch the latest GitHub release tag and compare it to the running version. If newer, show a small badge in the navbar that opens the releases page.

---

## Implementation

### 1. New file: `packages/user-interface/src/lib/check-for-updates.ts`

A single exported async function `checkForUpdates()`:

- Fetches `https://api.github.com/repos/ashleydavis/photosphere/releases/latest`
- Returns the latest version string (e.g. `"1.2.3"`) if a newer release exists, `undefined` otherwise
- Skips check (returns `undefined`) if current `version` is `"dev"` or contains `"nightly"` — those are non-release builds
- Version comparison: strip leading `v` from the GitHub tag, then compare to current `version`. If they differ, assume the GitHub version is newer (GitHub's `/releases/latest` always returns the newest non-prerelease tag)
- No semver library needed; simple string inequality is sufficient
- On any network or parse error, silently return `undefined`

### 2. Modify: `packages/user-interface/src/components/navbar.tsx`

- Add state: `const [updateVersion, setUpdateVersion] = useState<string | undefined>(undefined);`
- Add `useEffect` on mount that calls `checkForUpdates()` and sets state
- When `updateVersion` is set, render a small pill/badge in the navbar (near the About link) with text like `"v{updateVersion} available"` that opens `https://github.com/ashleydavis/photosphere/releases/latest` in a new tab

---

## Files Modified

| File | Change |
|------|--------|
| `packages/user-interface/src/lib/check-for-updates.ts` | New — update check logic |
| `packages/user-interface/src/components/navbar.tsx` | Add state, useEffect, and update badge UI |

---

## Verification

1. Run the dev frontend: `cd apps/dev-frontend && bun run start`
2. In `check-for-updates.ts`, temporarily return a hardcoded version string to verify the badge appears in the navbar
3. Verify the badge links to the GitHub releases page
4. Verify that with `version = "dev"`, no badge appears
5. Run `bun run compile` to confirm TypeScript compiles cleanly
6. Run `bun run test` to confirm all tests pass
