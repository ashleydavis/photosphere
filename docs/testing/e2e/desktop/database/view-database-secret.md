# Desktop Manual Test: View a Database Secret from the View Database Modal

Test that a secret linked to a database can be drilled into and revealed from
within the **View Database** modal.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

CLI commands are run from `apps/cli/`:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-desktop-test
```

---

### 2. Pre-create a database with the CLI

```bash
bun run start -- init --db /tmp/psi-desktop-test/db --yes
```

---

### 3. Add the database to the app

1. Navigate to the **Manage Databases** page in the desktop app.
2. Click **Add database**, enter `My Test DB` and `/tmp/psi-desktop-test/db`, then click **Add**.

Expected:
- The new entry appears on the Databases page.

---

### 4. Link a secret to the database

1. Click the **Edit** button for the `My Test DB` row.
2. Click **Configure secrets…**.
3. On the **Geocoding API Key** row, click **+ New**.
4. In the create-secret dialog, enter the name `smoke-geocoding` and the value `test-api-key-12345`, then click **Create**.
5. Confirm `smoke-geocoding` is now selected in the Geocoding API Key dropdown, then click **Save**.
6. Back in the Edit dialog, click **Save**.

Expected:
- The dialogs close without errors and the entry is updated.

---

### 5. Open the View Database modal

1. From the row for `My Test DB`, click the **View** button.

Expected:
- The **View Database** modal opens.
- The **Linked Secrets** section shows **Geocoding API Key** with the name `smoke-geocoding` and a **View Secret** button.

---

### 6. Drill into the linked secret

1. Click the **View Secret** button on the Geocoding API Key row.

Expected:
- A nested **View Secret** dialog opens for `smoke-geocoding`.
- The value is initially hidden (shown as `••••••••••`).

---

### 7. Reveal the secret value

1. Click **Reveal**.

Expected:
- The API key value `test-api-key-12345` is shown.
- No error toasts are visible.
