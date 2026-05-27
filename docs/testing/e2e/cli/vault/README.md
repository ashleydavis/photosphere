# CLI Vault Tests

Manual test scripts for the `psi secrets` vault commands. The same commands
back two storage backends — a plaintext on-disk vault and the OS keychain.

## Structure

- [plaintext/](plaintext/) - Tests against the file-backed plaintext vault
- [keychain/](keychain/) - Tests against the OS keychain backend
