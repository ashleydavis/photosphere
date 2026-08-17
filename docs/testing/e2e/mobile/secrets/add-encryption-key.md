# Mobile Manual Test: Add an Encryption Key

Test adding an encryption key to the phone's vault and using it to open an encrypted database.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

An encryption key in PEM form. Generate one from `apps/cli/`:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/manual-test.pem
```

## Steps

### 1. Add the key

1. Go to **Secrets** and add a secret of type encryption key.
2. Name it `manual-test-key` and give it the PEM.

Expected: It is saved and listed by name.

---

### 2. View it

1. Open the secret.

Expected:
- It is shown as an encryption key rather than as plain text.
- The value matches the PEM you generated.

---

### 3. Use it

1. Open an encrypted database that uses this key, as in [open-encrypted-database](../database/open-encrypted-database.md).

Expected: The database opens and its photos are readable, which is the only real proof the key was stored intact.

---

### 4. A malformed key

1. Add another encryption key, giving it text that is not a PEM.

Expected: The app refuses it and says why, rather than saving something that will fail later when a database needs it.
