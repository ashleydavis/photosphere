import { spawn } from "child_process";
import { ISecret, IVault, IPrereqCheckResult } from "./vault";
import { IKeychainPayload, toKeychainName, fromKeychainName, runCommand } from "./keychain-types";

//
// The secret-tool CLI name on Linux.
//
const SECRET_TOOL = "secret-tool";

//
// The keychain service name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Set to true once the tool availability check has been performed.
//
let toolChecked = false;

//
// Checks that secret-tool is installed and available on PATH.
// Returns ok=true on success, or ok=false with an error message on failure.
//
async function checkPrereqsOnce(): Promise<IPrereqCheckResult> {
    try {
        await runCommand(["which", SECRET_TOOL]);
        return { ok: true, message: undefined };
    }
    catch {
        return {
            ok: false,
            message: "secret-tool is not installed. Install it with: sudo apt install libsecret-tools",
        };
    }
}

//
// Checks that secret-tool is available, logging its version.
// Throws a clear error if the tool is not found, suggesting how to install it.
//
async function checkTool(): Promise<void> {
    if (toolChecked) {
        return;
    }
    toolChecked = true;
    const result = await checkPrereqsOnce();
    if (!result.ok) {
        throw new Error(result.message);
    }
    const path = await runCommand(["which", SECRET_TOOL]);
    console.log(`Using Linux Keychain via secret-tool (${path})`);
}

//
// Runs `secret-tool search` and returns the stderr output.
// secret-tool search writes attribute lines (attribute.account, attribute.service)
// to stderr and item details (label, secret value) to stdout, so capturing stderr
// is required to parse which secrets exist.
//
function runSecretToolSearch(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        const child = spawn(SECRET_TOOL, [
            "search", "--all",
            "service", KEYCHAIN_SERVICE,
        ], { stdio: ["pipe", "pipe", "pipe"] });

        const stderrChunks: Buffer[] = [];

        child.stderr.on("data", (chunk: Buffer) => {
            stderrChunks.push(chunk);
        });

        child.on("close", (code: number | null) => {
            if (code === 0 || code === 1) {
                resolve(Buffer.concat(stderrChunks).toString("utf8"));
            }
            else {
                reject(new Error(`secret-tool search exited with code ${code}`));
            }
        });

        child.on("error", (err: Error) => {
            reject(err);
        });
    });
}

//
// Runs `secret-tool store` with the given secret JSON piped to stdin.
// secret-tool store reads the password from stdin, which requires a
// dedicated spawn rather than the generic runCommand helper.
//
function runSecretToolStore(keychainName: string, json: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const child = spawn(SECRET_TOOL, [
            "store",
            `--label=${keychainName}`,
            "service", KEYCHAIN_SERVICE,
            "account", keychainName,
        ], { stdio: ["pipe", "pipe", "pipe"] });

        const stderrChunks: Buffer[] = [];

        child.stderr.on("data", (chunk: Buffer) => {
            stderrChunks.push(chunk);
        });

        child.on("close", (code: number | null) => {
            if (code === 0) {
                resolve();
            }
            else {
                const stderr = Buffer.concat(stderrChunks).toString("utf8").trim();
                reject(new Error(`secret-tool store exited with code ${code}. stderr: ${stderr}`));
            }
        });

        child.on("error", (err: Error) => {
            reject(err);
        });

        child.stdin.write(json, "utf8");
        child.stdin.end();
    });
}

//
// A vault implementation that persists secrets via the secret-tool CLI,
// which talks to any Secret Service API daemon (GNOME Keyring, KWallet, etc.).
//
// Every secret name stored is prefixed with "psi-" to make photosphere entries
// clearly identifiable.  Native listing via `secret-tool search` means no
// index file is needed on Linux.
//
export class LinuxKeychainVault implements IVault {
    //
    // Retrieves a secret by name from the Secret Service.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        await checkTool();
        const keychainName = toKeychainName(name);
        let raw: string;
        try {
            raw = await runCommand([SECRET_TOOL, "lookup", "service", KEYCHAIN_SERVICE, "account", keychainName]);
        }
        catch {
            return undefined;
        }
        if (raw === "") {
            return undefined;
        }
        const payload = JSON.parse(raw) as IKeychainPayload;
        return { name, type: payload.type, value: payload.value };
    }

    //
    // Creates or overwrites a secret in the Secret Service.
    //
    async set(secret: ISecret): Promise<void> {
        await checkTool();
        const keychainName = toKeychainName(secret.name);
        const payload: IKeychainPayload = { type: secret.type, value: secret.value };
        const json = JSON.stringify(payload);
        await runSecretToolStore(keychainName, json);
    }

    //
    // Returns all photosphere secrets from the Secret Service by searching
    // for entries with service=photosphere and parsing the account attribute.
    //
    async list(): Promise<ISecret[]> {
        await checkTool();
        let output: string;
        try {
            output = await runSecretToolSearch();
        }
        catch {
            return [];
        }

        const secrets: ISecret[] = [];
        const lines = output.split("\n");
        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed.startsWith("attribute.account = ")) {
                const keychainName = trimmed.slice("attribute.account = ".length).trim();
                if (keychainName.startsWith("psi-")) {
                    const name = fromKeychainName(keychainName);
                    const secret = await this.get(name);
                    if (secret !== undefined) {
                        secrets.push(secret);
                    }
                }
            }
        }
        return secrets;
    }

    //
    // Deletes a secret from the Secret Service.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        await checkTool();
        const keychainName = toKeychainName(name);
        try {
            await runCommand([SECRET_TOOL, "clear", "service", KEYCHAIN_SERVICE, "account", keychainName]);
        }
        catch {
            // Secret did not exist; ignore.
        }
    }

    //
    // Checks that secret-tool is installed and available on PATH.
    // Returns ok=true on success, or ok=false with an error message on failure.
    //
    async checkPrereqs(): Promise<IPrereqCheckResult> {
        return checkPrereqsOnce();
    }
}
