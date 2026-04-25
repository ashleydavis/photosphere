# Fix: S3 Credential Name Ignored During `configureS3IfNeeded`

## Problem Summary

When `configureS3IfNeeded` prompts the user for a credential name, the entered value is silently
ignored — the secret is always stored in the vault under the hardcoded key `'default:s3'`.
Likewise, `getDefaultS3Config` always looks up `'default:s3'` by name, so any credential stored
under a user-chosen name is never found by the fallback lookup.

**Fix:** Use the user-provided name as the vault secret key in `configureS3IfNeeded`, and update
`getDefaultS3Config` to search by type (`'s3-credentials'`) instead of by the fixed name.

---

## Implementation Tasks

### 1. `apps/cli/src/lib/init-cmd.ts` — `getDefaultS3Config`

Change the lookup from a fixed-name `vault.get('default:s3')` to a type-based search:

- Call `vault.list()` and find the first entry whose `type === 's3-credentials'`.
- Parse and return its credentials as before.
- Return `undefined` if no such entry is found.

This is backward-compatible: any secret already stored as `'default:s3'` with type
`'s3-credentials'` will still be found.

### 2. `apps/cli/src/lib/init-cmd.ts` — `configureS3IfNeeded`

Change the `vault.set` call so the vault key is the user-provided label instead of the hardcoded
`'default:s3'`:

- Replace `name: 'default:s3'` with `name: (label as string).trim()`.
- Remove the `label` field from inside the stored JSON value — it is now redundant because the
  user-chosen name is the vault key itself.

No callers need updating: `configureS3IfNeeded` returns the credentials object directly, not the
vault key name.

---

## Tests to Add

Create a new file: `apps/cli/src/test/lib/init-cmd.test.ts`

The following cases must be covered for `getDefaultS3Config`:

1. **Returns credentials when a `s3-credentials` secret exists with a custom name** — mock the
   vault to return a single secret with `type: 's3-credentials'` and a non-default name; assert
   that `getDefaultS3Config` returns the parsed `IS3Credentials` object.

2. **Returns `undefined` when no `s3-credentials` secret exists** — mock the vault to return an
   empty list; assert that `getDefaultS3Config` returns `undefined`.

3. **Returns the first `s3-credentials` secret when multiple exist** — mock the vault to return
   two secrets of type `'s3-credentials'`; assert that the credentials from the first entry are
   returned.

---

## Verification

Run each step in order; fix any failures before proceeding to the next.

1. `bun run compile` — must produce no TypeScript errors.
2. `bun run test` — all unit tests must pass.
3. `bun run test:cli` — CLI smoke tests must pass.
