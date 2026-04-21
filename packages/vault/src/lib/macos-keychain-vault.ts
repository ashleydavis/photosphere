import { ISecret, IVault, IPrereqCheckResult } from "./vault";
import { IKeychainPayload, KEYCHAIN_PREFIX, toKeychainName, fromKeychainName, runCommand } from "./keychain-types";

//
// The fixed path to the macOS security CLI tool.
//
const SECURITY_TOOL = "/usr/bin/security";

//
// The keychain service name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Parses the output of `security dump-keychain` and returns the account names
// of all entries whose service matches KEYCHAIN_SERVICE and whose account name
// starts with the psi- prefix.
//
// Each entry block in the dump output starts with a "keychain:" line and
// contains attribute lines of the form `"tag"<type>="value"`.
// Attribute metadata (names, labels) is returned without auth prompts;
// only secret values require user authorization.
//
function parseKeychainDump(output: string): string[] {
    const keychainNames: string[] = [];
    const blocks = output.split(/^keychain:/m);
    for (const block of blocks) {
        const svceMatch = block.match(/"svce"<blob>="([^"]+)"/);
        const acctMatch = block.match(/"acct"<blob>="([^"]+)"/);
        if (
            svceMatch && svceMatch[1] === KEYCHAIN_SERVICE &&
            acctMatch && acctMatch[1].startsWith(KEYCHAIN_PREFIX)
        ) {
            keychainNames.push(acctMatch[1]);
        }
    }
    return keychainNames;
}

//
// A vault implementation that persists secrets in the macOS Keychain using
// the /usr/bin/security CLI tool.
//
// Listing uses `security dump-keychain` filtered to our psi- prefix on the
// account field, which returns metadata without triggering auth prompts.
// This avoids any index file and keeps the vault self-consistent.
//
// Every secret name stored in the keychain is prefixed with "psi-" to make
// photosphere entries clearly identifiable in the Keychain Access UI.
//
export class MacOSKeychainVault implements IVault {
    //
    // Set to true once the tool availability check has been performed.
    //
    private toolChecked: boolean = false;

    //
    // Checks that /usr/bin/security is present and executable.
    // Returns ok=true on success, or ok=false with an error message on failure.
    //
    async checkPrereqs(): Promise<IPrereqCheckResult> {
        try {
            await runCommand([SECURITY_TOOL, "version"]);
            return { ok: true, message: undefined };
        }
        catch {
            return {
                ok: false,
                message: `macOS Keychain tool not found at ${SECURITY_TOOL}. This tool is bundled with macOS and should always be present.`,
            };
        }
    }

    //
    // Verifies that the security CLI tool is available, logging its version.
    // Throws a helpful error if the tool is not found.
    //
    private async checkTool(): Promise<void> {
        if (this.toolChecked) {
            return;
        }
        this.toolChecked = true;
        const result = await this.checkPrereqs();
        if (!result.ok) {
            throw new Error(result.message);
        }
        await runCommand([SECURITY_TOOL, "version"]);
    }

    //
    // Retrieves a secret by name from the macOS Keychain.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        await this.checkTool();
        const keychainName = toKeychainName(name);
        let raw: string;
        try {
            raw = await runCommand([SECURITY_TOOL, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", keychainName, "-w"]);
        }
        catch {
            return undefined;
        }
        const payload = JSON.parse(raw) as IKeychainPayload;
        return { name, type: payload.type, value: payload.value };
    }

    //
    // Creates or overwrites a secret in the macOS Keychain.
    //
    async set(secret: ISecret): Promise<void> {
        await this.checkTool();
        const keychainName = toKeychainName(secret.name);
        const payload: IKeychainPayload = { type: secret.type, value: secret.value };
        const json = JSON.stringify(payload);
        await runCommand([SECURITY_TOOL, "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", keychainName, "-w", json]);
    }

    //
    // Returns all photosphere secrets in the macOS Keychain by parsing
    // `security dump-keychain` output for entries matching our service name
    // and psi- account prefix, then fetching each secret individually.
    //
    async list(): Promise<ISecret[]> {
        await this.checkTool();
        let output: string;
        try {
            output = await runCommand([SECURITY_TOOL, "dump-keychain"]);
        }
        catch {
            return [];
        }
        const keychainNames = parseKeychainDump(output);
        const secrets: ISecret[] = [];
        for (const keychainName of keychainNames) {
            const name = fromKeychainName(keychainName);
            const secret = await this.get(name);
            if (secret !== undefined) {
                secrets.push(secret);
            }
        }
        return secrets;
    }

    //
    // Deletes a secret from the macOS Keychain.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        await this.checkTool();
        const keychainName = toKeychainName(name);
        try {
            await runCommand([SECURITY_TOOL, "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", keychainName]);
        }
        catch {
            // Secret did not exist; ignore.
        }
    }
}

//
// Re-export the prefix constant so callers can refer to it without importing
// keychain-types directly.
//
export { KEYCHAIN_PREFIX };
