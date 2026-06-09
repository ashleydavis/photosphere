# Desktop Secrets Tests

Manual test scripts for managing secrets through the Photosphere desktop app.

## Tests

- [add-api-key.md](add-api-key.md) - Add and edit an api-key secret (raw value, no JSON envelope)
- [add-encryption-key.md](add-encryption-key.md) - Add and edit an encryption-key secret (raw PEM, no JSON envelope)
- [add-s3-credentials.md](add-s3-credentials.md) - Add and edit an s3-credentials secret (JSON envelope, no label field)
- [view-secret.md](view-secret.md) - View a secret value (with reveal)
- [rename-secret.md](rename-secret.md) - Rename a secret (vault key matches the new name)
- [add-duplicate-name.md](add-duplicate-name.md) - Adding a duplicate-named secret shows an error
