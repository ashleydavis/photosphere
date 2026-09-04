# Mobile Manual Test: LAN Share, CLI to Phone

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the `psi` CLI sending a database entry and a secret to the phone on the same network. The phone is the target.

## Prerequisites

The phone running the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The CLI on a machine on the same local network, run from `apps/cli/`:

```bash
cd apps/cli/
```

The phone must be on Wi-Fi, not mobile data.

## Steps

### 1. Receive a secret from the CLI

1. On the phone, go to **Secrets** and start receiving. Note the pairing code.
2. On the machine:

   ```bash
   bun run start -- secrets send --name <secret name> --yes --code <pairing code>
   ```

Expected:
- The CLI reports that it found a device and sent the secret.
- The phone lists the secret with the value it had on the machine.

---

### 2. Receive a database entry from the CLI

1. On the phone, start receiving a database entry and note the code.
2. On the machine:

   ```bash
   bun run start -- dbs send --name <database name> --yes --code <pairing code>
   ```

Expected:
- The entry arrives and is listed on the phone.
- Opening it loads the assets.

---

### 3. The CLI cannot find the phone

1. Put the phone on mobile data, or on a different network from the machine.
2. Start receiving on the phone and send from the CLI.

Expected: The CLI says no device was found within its window. It does not report success, and the phone does not show a half-finished transfer.

---

### 4. The wrong code

1. Start receiving on the phone and note its code.
2. Send from the CLI with a different code.

Expected: The CLI says a device was found but is using a different code, rather than sending the secret to a device that could not prove it had the code.

---

### 5. Check what arrived is what was sent

For a secret, compare it against the machine's copy:

```bash
bun run start -- secrets view --name <secret name>
```

Expected: The value on the phone matches character for character. A secret that arrives truncated or re-encoded fails later, when a database will not open, and is much harder to trace from there.
