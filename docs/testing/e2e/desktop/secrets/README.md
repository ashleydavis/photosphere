# Desktop Secrets Tests

Manual test scripts for managing secrets through the Photosphere desktop app.

## Tests

- [add-secret.md](add-secret.md) - Add a secret via the UI
- [view-secret.md](view-secret.md) - View a secret value (with reveal)
- [edit-encryption-key.md](edit-encryption-key.md) - Edit an encryption-key secret (raw PEM, no JSON envelope)
- [edit-api-key.md](edit-api-key.md) - Edit an API-key secret
- [edit-s3-credentials.md](edit-s3-credentials.md) - Edit an S3-credentials secret (JSON envelope)
- [rename-secret.md](rename-secret.md) - Rename a secret (vault key matches the new name)
- [add-duplicate-name.md](add-duplicate-name.md) - Adding a duplicate-named secret shows an error
