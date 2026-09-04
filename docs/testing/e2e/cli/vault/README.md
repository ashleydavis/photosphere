# CLI Vault Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for the `psi secrets` vault commands. The same commands
back two storage backends — a plaintext on-disk vault and the OS keychain.

## Structure

- [plaintext/](plaintext/) - Tests against the file-backed plaintext vault
- [keychain/](keychain/) - Tests against the OS keychain backend
