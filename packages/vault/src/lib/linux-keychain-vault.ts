import { spawn } from "child_process";
import { ISecret, IVault, IPrereqCheckResult } from "./vault";
import { toKeychainName, fromKeychainName, runCommand } from "./keychain-types";

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
    await runCommand(["which", SECRET_TOOL]);
}

//
// A parsed entry from `secret-tool search` stderr output.
//
interface ISearchEntry {
    //
    // The keychain account name (includes psi- prefix).
    //
    account: string;

    //
    // The photosphere secret type stored as the secrettype attribute.
    //
    secretType: string;
}

//
// Parses `secret-tool search` stderr output into account/secrettype pairs.
// Each entry block contains attribute lines; blank lines separate entries.
//
function parseSearchOutput(output: string): ISearchEntry[] {
    const entries: ISearchEntry[] = [];
    let currentAccount: string | undefined;
    let currentSecretType: string | undefined;

    const flushEntry = () => {
        if (currentAccount !== undefined && currentAccount.startsWith("psi-")) {
            entries.push({ account: currentAccount, secretType: currentSecretType ?? "plain" });
        }
        currentAccount = undefined;
        currentSecretType = undefined;
    };

    for (const line of output.split("\n")) {
        const trimmed = line.trim();
        if (trimmed.startsWith("attribute.account = ")) {
            flushEntry();
            currentAccount = trimmed.slice("attribute.account = ".length).trim();
        }
        else if (trimmed.startsWith("attribute.secrettype = ")) {
            currentSecretType = trimmed.slice("attribute.secrettype = ".length).trim();
        }
        else if (trimmed === "") {
            flushEntry();
        }
    }
    flushEntry();

    return entries;
}

//
// Runs `secret-tool search` filtered to our service and returns the stderr output.
// secret-tool search writes attribute lines to stderr, so capturing stderr
// is required to parse which secrets exist and their types.
//
function runSecretToolSearchAll(): Promise<string> {
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
// Runs `secret-tool search` for a single account and returns the stderr output.
// Used by get() to retrieve the secrettype attribute for a specific entry.
//
function runSecretToolSearchOne(keychainName: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        const child = spawn(SECRET_TOOL, [
            "search", "--all",
            "service", KEYCHAIN_SERVICE,
            "account", keychainName,
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
// Runs `secret-tool store` with the secret value piped to stdin.
// The secret type is stored as a `secrettype` attribute so the raw value
// is visible in keychain GUI tools instead of a JSON wrapper.
//
function runSecretToolStore(keychainName: string, secretType: string, value: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        const child = spawn(SECRET_TOOL, [
            "store",
            `--label=${keychainName}`,
            "service", KEYCHAIN_SERVICE,
            "account", keychainName,
            "secrettype", secretType,
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

        child.stdin.write(value, "utf8");
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
// The secret type is stored as a `secrettype` attribute so the raw secret value
// is visible in keychain GUI tools instead of being wrapped in JSON.
//
export class LinuxKeychainVault implements IVault {
    //
    // Retrieves a secret by name from the Secret Service.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        await checkTool();
        const keychainName = toKeychainName(name);
        let value: string;
        try {
            value = await runCommand([SECRET_TOOL, "lookup", "service", KEYCHAIN_SERVICE, "account", keychainName]);
        }
        catch {
            return undefined;
        }
        if (value === "") {
            return undefined;
        }
        const searchOutput = await runSecretToolSearchOne(keychainName);
        const entries = parseSearchOutput(searchOutput);
        const secretType = entries.find(entry => entry.account === keychainName)?.secretType ?? "plain";
        return { name, type: secretType, value };
    }

    //
    // Creates or overwrites a secret in the Secret Service.
    // The type is stored as a keychain attribute; the value is stored as-is.
    //
    async set(secret: ISecret): Promise<void> {
        await checkTool();
        const keychainName = toKeychainName(secret.name);
        await runSecretToolStore(keychainName, secret.type, secret.value);
    }

    //
    // Returns all photosphere secrets from the Secret Service.
    // Reads type from the secrettype attribute and value from a per-entry lookup.
    //
    async list(): Promise<ISecret[]> {
        await checkTool();
        let output: string;
        try {
            output = await runSecretToolSearchAll();
        }
        catch {
            return [];
        }

        const entries = parseSearchOutput(output);
        const secrets: ISecret[] = [];

        for (const entry of entries) {
            const name = fromKeychainName(entry.account);
            let value: string;
            try {
                value = await runCommand([SECRET_TOOL, "lookup", "service", KEYCHAIN_SERVICE, "account", entry.account]);
            }
            catch {
                continue;
            }
            if (value === "") {
                continue;
            }
            secrets.push({ name, type: entry.secretType, value });
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
