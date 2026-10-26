# CLI Encryption Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for encrypted databases.

## Tests

- [encrypt-in-place.md](encrypt-in-place.md) - `encrypt` turns a plain database into an encrypted one
- [decrypt-in-place.md](decrypt-in-place.md) - `decrypt` turns an encrypted database back into a plain one
- [replicate-encrypted.md](replicate-encrypted.md) - Replicate an encrypted database
- [sync-encrypted.md](sync-encrypted.md) - Sync two copies of an encrypted database
