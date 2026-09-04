# CLI Plaintext Vault Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for the file-backed plaintext vault.

## Tests

- [list-empty.md](list-empty.md) - Empty vault shows `No secrets`
- [add-secret.md](add-secret.md) - Add a secret via CLI flags
- [view-secret.md](view-secret.md) - View a secret value
- [edit-secret.md](edit-secret.md) - Edit a secret value and rename it
- [delete-secret.md](delete-secret.md) - Remove a secret while keeping the rest of the vault intact
- [add-duplicate-fails.md](add-duplicate-fails.md) - Adding a secret with a duplicate name fails
- [clear.md](clear.md) - `secrets clear --yes` removes all secrets
- [import-pem.md](import-pem.md) - Import a PEM private key as an encryption key
- [list-shared.md](list-shared.md) - Shared-id secrets appear in `secrets list`
