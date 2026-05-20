# Plan: Trim whitespace from user-provided inputs

## Problem

User-typed paths, names, and credentials are not trimmed before use. A leading or trailing space in a path turns an absolute path into a relative one, silently creating data in the wrong location. Spaces in names break vault lookups. Spaces in S3 credentials and API keys cause API failures.

## Approach

Trim at the point of use (form submission / command handler entry), not on every keystroke. For the CLI, trim `cmdOptions` values at the start of each command handler. For UI, trim form fields in the submit handler.

---

## Step 1 -- create-database-modal.tsx

File: `packages/user-interface/src/components/create-database-modal.tsx`

In `handleCreate()`, trim `form.path` before all uses:
- `path: form.path` -> `path: form.path.trim()`
- `await platform.createDatabaseAtPath(form.path)` -> `await platform.createDatabaseAtPath(form.path.trim())`
- `await openDatabase(form.path)` -> `await openDatabase(form.path.trim())`

---

## Step 2 -- add-database-modal.tsx

File: `packages/user-interface/src/components/add-database-modal.tsx`

In `handleAdd()`, trim `form.path` before all uses (same pattern as Step 1):
- `path: form.path` -> `path: form.path.trim()`
- `await openDatabase(form.path)` -> `await openDatabase(form.path.trim())`

---

## Step 3 -- replicate-database-dialog.tsx

File: `packages/user-interface/src/components/replicate-database-dialog.tsx`

In `handleStart()`, trim `form.destPath` when building `IReplicateDatabaseData`:
- `destPath: form.destPath` -> `destPath: form.destPath.trim()`

Also fix the same-path equality guard (currently `form.destPath === sourceEntry.path`) to compare trimmed values:
- `form.destPath === sourceEntry.path` -> `form.destPath.trim() === sourceEntry.path`

---

## Step 4 -- share-database-dialog.tsx

File: `packages/user-interface/src/components/share-database-dialog.tsx`

In the submit handler, trim `form.name` and `form.path` before passing in the payload:
- `name: form.name` -> `name: form.name.trim()`
- `path: form.path` -> `path: form.path.trim()`

---

## Step 5 -- receive-database-dialog.tsx

File: `packages/user-interface/src/components/receive-database-dialog.tsx`

In `doImport()` (around line 278), trim `editedPath` before passing to the platform call:
- `path: editedPath` -> `path: editedPath.trim()`

---

## Step 6 -- receive-secret-dialog.tsx

File: `packages/user-interface/src/components/receive-secret-dialog.tsx`

In the save handler (around line 104), trim `saveName` before use:
- `saveName,` -> `saveName: saveName.trim(),`

---

## Step 7 -- secrets-form.ts (buildValueJson)

File: `packages/user-interface/src/lib/secrets-form.ts`

In `buildValueJson()`, trim all credential fields before serialising:
- `region: form.s3Region` -> `region: form.s3Region.trim()`
- `accessKeyId: form.s3AccessKeyId` -> `accessKeyId: form.s3AccessKeyId.trim()`
- `secretAccessKey: form.s3SecretAccessKey` -> `secretAccessKey: form.s3SecretAccessKey.trim()`
- `obj.endpoint = form.s3Endpoint` -> `obj.endpoint = form.s3Endpoint.trim()`
- `return form.apiKey` (api-key branch) -> `return form.apiKey.trim()`

---

## Step 8 -- create-secret-dialog.tsx

File: `packages/user-interface/src/components/create-secret-dialog.tsx`

In `handleSave()` (around line 51), trim `form.name` before passing to `platform.addSecret`:
- `{ name: form.name, type: secretType }` -> `{ name: form.name.trim(), type: secretType }`

---

## Step 9 -- CLI directory-picker.ts

File: `apps/cli/src/lib/directory-picker.ts`

In the `'fullpath'` branch, trim the typed value before resolving (line ~169):
- `const resolvedPath = resolve(String(fullPath))` -> `const resolvedPath = resolve(String(fullPath).trim())`

In the `'subdirectory'` branch, trim the typed name before joining (line ~133-134):
- `const subdirPath = join(currentPath, String(subdirName))` -> `const subdirPath = join(currentPath, String(subdirName).trim())`
- `const relativePath = \`./${String(subdirName)}\`` -> `const relativePath = \`./${String(subdirName).trim()}\``

---

## Step 10 -- CLI init-cmd.ts (PEM file path prompts)

File: `apps/cli/src/lib/init-cmd.ts`

Two places prompt the user for a PEM file path with `text()` and pass it straight to `fs.readFile` without trimming. Trim both:

- Line ~385: `const pem = await fs.readFile(filePath as string, 'utf-8')` -> `const pem = await fs.readFile((filePath as string).trim(), 'utf-8')`
- Line ~434: same fix in the second occurrence

---

## Step 11 -- CLI dbs.ts command handler

File: `apps/cli/src/cmd/dbs.ts`

At the top of the `--yes` path in `dbsAdd()` (around line 461), trim all relevant cmdOptions before use:

```typescript
cmdOptions.name = cmdOptions.name.trim();
cmdOptions.path = cmdOptions.path.trim();
if (cmdOptions.description) cmdOptions.description = cmdOptions.description.trim();
if (cmdOptions.encryptionKey) cmdOptions.encryptionKey = cmdOptions.encryptionKey.trim();
if (cmdOptions.s3Cred) cmdOptions.s3Cred = cmdOptions.s3Cred.trim();
if (cmdOptions.geocodingKey) cmdOptions.geocodingKey = cmdOptions.geocodingKey.trim();
```

Apply the same pattern at the top of `dbsEdit()` (around line 652), trimming `cmdOptions.name`, `cmdOptions.newName`, `cmdOptions.path`, `cmdOptions.description`, `cmdOptions.encryptionKey`, `cmdOptions.s3Cred`, `cmdOptions.geocodingKey`.

---

## Step 12 -- CLI secrets.ts command handler

File: `apps/cli/src/cmd/secrets.ts`

At the top of the `--yes` path in `secretsAdd()` (around line 193), trim all relevant cmdOptions before use:

```typescript
cmdOptions.name = cmdOptions.name.trim();
cmdOptions.value = cmdOptions.value.trim();
```

At the top of `secretsEdit()` (around line 455), trim:

```typescript
if (cmdOptions.newName) cmdOptions.newName = cmdOptions.newName.trim();
if (cmdOptions.valueFile) cmdOptions.valueFile = cmdOptions.valueFile.trim();
if (cmdOptions.value) cmdOptions.value = cmdOptions.value.trim();
```

---

## Out of scope

- `--db` / `--dest` flags typed on the shell command line -- the shell handles quoting; accidental whitespace is unlikely there.
- Bug report text fields (`bug.ts`) -- free text, not used for lookups or filesystem access.
- PEM key content (not the file path) -- PEM blocks have internal line structure; outer trim is safe but the risk is low enough to skip for now.
- Description fields across all modals -- user-facing only, no lookup or filesystem use.
