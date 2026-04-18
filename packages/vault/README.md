# vault

Cross-platform secrets management package for Photosphere.

Provides a uniform interface (`IVault`) for storing, retrieving, listing, and
deleting secrets.  Multiple backend implementations can be registered behind
the same interface — local key-ring, Bitwarden, 1Password, etc.  The only
backend shipped in this package is `PlaintextVault`, which stores secrets as
JSON files on the local filesystem.

---

## Concepts

### `ISecret`

```ts
interface ISecret {
    name:  string;   // unique identifier within the vault
    type:  string;   // caller-defined category (see examples below)
    value: string;   // the secret, serialised as a string
}
```

The `type` field is an **opaque string** — the `vault` package never inspects
it.  Callers choose whatever categories make sense for their domain.  Examples
used in Photosphere:

| Suggested type string | Contents of `value`                                   |
|-----------------------|--------------------------------------------------------|
| `"password"`          | A plain passphrase                                     |
| `"key-pair"`          | JSON: `{ privateKey: string, publicKey: string }`      |
| `"s3-credentials"`    | JSON: `{ accessKeyId: string, secretAccessKey: string }`|
| `"api-key"`           | A raw API token / key string                           |

Because `value` is always a `string`, structured types (key pairs, S3
credentials) should be serialised with `JSON.stringify` before storing and
deserialised with `JSON.parse` after retrieval.

### `IVault`

```ts
interface IVault {
    get(name: string): Promise<ISecret | undefined>;
    set(secret: ISecret): Promise<void>;
    list(): Promise<ISecret[]>;
    delete(name: string): Promise<void>;
}
```

---

## Vault backends

### `"plaintext"` — plain-text filesystem vault

Stores each secret as a separate JSON file inside a directory.

**Default directory:** `~/.config/vault/`

Each secret is stored in a file named after the (percent-encoded) secret name
with a `.json` extension, e.g.:

```
~/.config/vault/
    my-api-key.json
    org%2Frepo%2Ftoken.json
    db-password.json
```

> **Security:** Files are created with mode **0600** (owner read/write only)
> and the vault directory with mode **0700** (owner only) on POSIX systems
> (Linux, macOS).  On Windows, POSIX permissions are not available; take
> appropriate OS-level precautions.
>
> This vault stores secrets **unencrypted**.  It is intended for development
> and low-sensitivity use cases.  For production use, prefer an encrypted or
> hardware-backed backend.

#### Usage

```ts
import { getVault, ISecret } from "vault";

const vault = getVault("plaintext");

// Store a secret
await vault.set({ name: "my-api-key", type: "api-key", value: "sk-abc123" });

// Retrieve a secret
const secret: ISecret | undefined = await vault.get("my-api-key");

// List all secrets
const all: ISecret[] = await vault.list();

// Delete a secret
await vault.delete("my-api-key");
```

`getVault` returns the same instance every time it is called with the same type
string, so it is safe to call it at the top of any module without worrying
about creating duplicate instances.

---

## Adding a new vault backend

**Step 1** — implement the `IVault` interface:

```ts
import { IVault, ISecret } from "vault";

export class BitwiedenVault implements IVault {
    async get(name: string): Promise<ISecret | undefined> { /* ... */ }
    async set(secret: ISecret): Promise<void>             { /* ... */ }
    async list(): Promise<ISecret[]>                      { /* ... */ }
    async delete(name: string): Promise<void>             { /* ... */ }
}
```

**Step 2** — register the type string in `instantiateVault` inside
[src/lib/get-vault.ts](src/lib/get-vault.ts):

```ts
function instantiateVault(type: string): IVault {
    if (type === "plaintext") {
        return new PlaintextVault();
    }
    if (type === "bitwarden") {
        return new BitwardenVault();
    }
    throw new Error(`Unknown vault type: "${type}". Supported types: "plaintext", "bitwarden".`);
}
```

After that, `getVault("bitwarden")` will work everywhere.

---

## Running the tests

```sh
cd packages/vault
bun run test
```
