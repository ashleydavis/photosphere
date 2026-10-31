# Use AWS_ENDPOINT_URL instead of AWS_ENDPOINT

## Overview

`psi` reads a custom S3 endpoint from `AWS_ENDPOINT`, which is not a name any AWS tool recognises. The AWS SDKs and Tools reference standardises on `AWS_ENDPOINT_URL` for a global endpoint override and `AWS_ENDPOINT_URL_S3` for one that applies to S3 only, and the AWS CLI has honoured those since v2.13. The bundled `@aws-sdk/client-s3` already resolves both of its own accord: the built worker bundle contains `ENV_ENDPOINT_URL = "AWS_ENDPOINT_URL"`, so the SDK under `psi` today already knows the standard name while `psi` itself does not. The result is that one shell cannot drive both tools. A shell set up to run the `psi` commands in a test cannot run `aws s3` against the same bucket, and `aws` fails with `InvalidAccessKeyId` because it went to real AWS instead. This plan replaces the non-standard name with the standard ones everywhere `psi` reads an endpoint, and updates every script, test and document that exports the old name. Backward compatibility is not kept: `AWS_ENDPOINT` stops being read.

## Issues

## Steps

1. **Write documentation.** Update `docs/storage-paths.md` (the paragraph at line 41 that names `AWS_ENDPOINT`) to say that the endpoint comes from the vault entry when there is one, and otherwise from `AWS_ENDPOINT_URL_S3` or `AWS_ENDPOINT_URL`, with the S3-specific name winning when both are set. Say that these are the names the AWS CLI and every AWS SDK use, so one exported endpoint serves `psi` and `aws` together. Update `docs/testing/e2e/mobile/auto-import/auto-import-full-flow.md` line 22 to name `AWS_ENDPOINT_URL`, and delete the `InvalidAccessKeyId` note added to step 16 item 1, which exists only to explain the two names diverging and stops being true. Update `CLOUD_STORAGE_TESTS.md` line 23. **STOP when this step is written. Do not continue to step 2.** Wait for the human to review and approve the documentation. If the human revises it, revise the remaining steps to match before implementing anything.

2. **Add the resolution function.** In `packages/storage/src/lib/cloud-storage.ts`, add an exported function above the `CloudStorage` class: `endpointFromEnvironment(env: NodeJS.ProcessEnv): string | undefined`. It returns `AWS_ENDPOINT_URL_S3` when that is a non-empty string, otherwise `AWS_ENDPOINT_URL` when that is a non-empty string, otherwise undefined. An empty string must not be treated as an endpoint, because an exported-but-empty variable would otherwise become an endpoint of `""` and produce a failure that names nothing. It takes the environment as an argument rather than reading `process.env` directly so a test can drive it without mutating global state. Give it a comment block saying why the two names exist and which wins. The function is reachable from `node-api` already, because `packages/storage/src/index.ts` re-exports everything from `./lib/cloud-storage`. Write its unit tests and watch them fail before the function exists. `bun run compile` must be clean and the storage suite must pass before this step is done.

3. **Use it in `CloudStorage`.** In the same file, change the constructor line `const endpoint = credentials?.endpoint || process.env.AWS_ENDPOINT;` to fall back to `endpointFromEnvironment(process.env)`. The credentials passed in still win, which is the vault path and is unchanged. `bun run compile` clean and the storage suite passing before this step is done.

4. **Use it in `resolveStorageCredentials`.** In `packages/node-api/src/lib/resolve-storage-credentials.ts`, in the environment-variable branch that builds `s3Config`, change `endpoint: process.env.AWS_ENDPOINT` to `endpoint: endpointFromEnvironment(process.env)`, importing the function from `storage` alongside the existing `IS3Credentials` import. Add tests to `packages/node-api/src/test/lib/resolve-storage-credentials.test.ts` covering the environment path, and change `clearEnvVars` in that file to delete `AWS_ENDPOINT_URL` and `AWS_ENDPOINT_URL_S3` rather than `AWS_ENDPOINT`, so the new variables cannot leak between tests. `bun run compile` clean and the node-api suite passing before this step is done.

5. **Update the shell that exports the variable.** Change every `export AWS_ENDPOINT=` to `export AWS_ENDPOINT_URL=` in: `apps/cli/smoke-tests/lib/common.sh` (in `export_s3_env_credentials`, and update that function's comment block if it names the variable), `apps/smoke-tests/tests/42-s3-sync-prefetch/test.sh`, `apps/smoke-tests/tests/43-s3-failure/test.sh`, `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh` and `apps/smoke-tests/tests/50-background-sync/test.sh`. In `apps/cli/smoke-tests/66-s3-vault-credentials/test.sh` change the `unset` line to unset `AWS_ENDPOINT_URL` and `AWS_ENDPOINT_URL_S3`: that test proves the vault path works with no environment credentials present, so it must unset the names the code now reads or it stops proving anything.

6. **Update the remaining references.** In `run-cloud-storage-tests.sh` change the two `AWS_ENDPOINT` mentions and the `-n` check to `AWS_ENDPOINT_URL`. In `packages/storage/integration-tests/cloud-storage.test.ts` change the comment at line 9. In `scripts/clear-s3-bucket.js` change the `process.env.AWS_ENDPOINT` read, or delete the file: see Notes, and ask the human which before deleting anything.

7. **Prove the old name is gone.** Run `grep -rn "AWS_ENDPOINT\b" . | grep -v node_modules | grep -v "^./.git/" | grep -v "docs/plans/"` and confirm the only remaining hits are inside the two built `worker.bundle.js` artifacts (`apps/ios-frontend/ios/App/App/worker.bundle.js` and `apps/android-frontend/android/app/src/main/assets/worker.bundle.js`), which are build output and are regenerated by the mobile builds. Do not hand-edit either bundle.

8. **Run the full set.** `bun run test:everything`, with no flags. Every suite it selects must pass. The S3 smoke tests changed in step 5 are the ones that prove the new variable actually reaches the SDK, so confirm from the run output that they were among the suites run, and if the change gate did not select them, name them explicitly to `test:everything` and run those.

9. **Update documentation to match.** Re-read the docs written in step 1 against the code as it ended up and correct anything that drifted, including the precedence between the two variable names if step 2's implementation settled it differently.

## Unit Tests

New, in `packages/storage/src/tests/cloud-storage-endpoint.test.ts` (this package keeps its tests in `src/tests`, plural, which differs from the `src/test` the repository style notes give; follow the package):

- `endpointFromEnvironment` returns undefined when neither variable is set.
- `endpointFromEnvironment` returns `AWS_ENDPOINT_URL` when only that is set.
- `endpointFromEnvironment` returns `AWS_ENDPOINT_URL_S3` when only that is set.
- `endpointFromEnvironment` prefers `AWS_ENDPOINT_URL_S3` over `AWS_ENDPOINT_URL` when both are set.
- `endpointFromEnvironment` treats an empty `AWS_ENDPOINT_URL` as not set and returns undefined.
- `endpointFromEnvironment` treats an empty `AWS_ENDPOINT_URL_S3` as not set and falls through to `AWS_ENDPOINT_URL`.
- `endpointFromEnvironment` ignores `AWS_ENDPOINT`, which is no longer read.

Updated, in `packages/node-api/src/test/lib/resolve-storage-credentials.test.ts`:

- The environment-credentials path puts `AWS_ENDPOINT_URL` into `s3Config.endpoint`.
- The environment-credentials path prefers `AWS_ENDPOINT_URL_S3` when both are set.
- The environment-credentials path leaves `s3Config.endpoint` undefined when neither is set.
- A vault entry's endpoint still wins over both environment variables.

The `CloudStorage` constructor is not unit tested directly: it builds a real `S3Client`, and step 2 exists so the decision it makes is in a plain function that is.

## Smoke Tests

No new smoke test. The behaviour is already covered by the existing S3 suites, which reach a local S3 emulator through nothing but this variable, so they fail if the new name does not reach the SDK. Step 5 changes what they export and step 8 runs them:

- `apps/cli/smoke-tests/lib/common.sh` `export_s3_env_credentials`, used by the CLI S3 suites.
- `apps/smoke-tests/tests/42-s3-sync-prefetch`, `43-s3-failure`, `45-s3-share-replica-sync`, `50-background-sync`.
- `apps/cli/smoke-tests/66-s3-vault-credentials`, which proves the vault path with no environment endpoint present, and so proves the fallback is genuinely absent rather than quietly still reading the old name.

## Verify

- `bun run compile` is clean.
- The storage unit suite passes, including the new endpoint tests, and each new test has been watched failing before the function existed.
- The node-api unit suite passes, including the updated credential-resolution tests.
- `bun run test:everything` passes with no flags, and the S3 smoke suites named above are among the suites it ran.
- The grep in step 7 finds `AWS_ENDPOINT` nowhere outside the two built worker bundles.
- With `AWS_ENDPOINT_URL` and the bucket's keys exported, `psi summary --db s3:<bucket>/<prefix>` and `aws s3 ls s3://<bucket>/<prefix>/` both reach the same bucket from the same shell. This is the thing the change is for, and it does not work today.

## Notes

`AWS_ENDPOINT` is not an AWS name. It is a convention some third-party tools adopted before AWS standardised one. The standard is `AWS_ENDPOINT_URL` for all services and `AWS_ENDPOINT_URL_<SERVICE>` for one, with the service-specific name taking precedence, and the AWS CLI has read them since v2.13.

Both names are supported rather than just the global one because `psi` talks to nothing but S3, so a person who has set `AWS_ENDPOINT_URL_S3` for their other tooling would otherwise find `psi` ignoring it while `aws` honours it, which is the same split this change exists to close.

Backward compatibility is deliberately not kept, per the repository's standing rule. Anything outside this repository that exports `AWS_ENDPOINT` for `psi` stops working and has to be updated, and there is no warning path for it: adding a "you set the old name" warning means keeping a read of the old name, which is the thing being removed.

`apps/mk-cli/README.md` already documents `AWS_ENDPOINT_URL`, and nothing in `apps/mk-cli` reads any endpoint variable at all. That README is describing something that is not there. It is out of scope here and left alone, but it is worth telling the human about, because it means the standard name was already the documented one in part of this repository.

`scripts/clear-s3-bucket.js` reads `AWS_ENDPOINT` and is a problem independent of this change: it is JavaScript in a repository whose rules allow only TypeScript and shell, it imports `aws-sdk` (the v2 SDK, which is not a dependency of this repository), and nothing references it from `package.json` or any script. It looks like dead code. Step 6 changes the variable name in it as the minimal action, but ask the human whether to delete it instead, and do not delete it without an answer.

The two `worker.bundle.js` files under `apps/ios-frontend` and `apps/android-frontend` are build artifacts containing a compiled copy of `cloud-storage.ts` and the AWS SDK. They will still show the old name until a mobile build regenerates them. They must not be hand-edited.

On mobile the environment fallback never fires: `packages/mobile-worker/src/lib/install-globals.ts` gives the embedded engine a `process` whose `env` is an empty object, and mobile credentials always come from the vault. Reading a different variable name there changes nothing and cannot throw.
