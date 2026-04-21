import { ISecret, IVault, IPrereqCheckResult } from "./vault";
import { IKeychainPayload, toKeychainName, fromKeychainName, runCommand } from "./keychain-types";

//
// The keychain resource name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Set to true once the tool availability check has been performed.
//
let toolChecked = false;

//
// Checks that PowerShell is available and executable.
// Returns ok=true on success, or ok=false with an error message on failure.
//
async function checkPrereqsOnce(): Promise<IPrereqCheckResult> {
    try {
        await runCommand(["powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"]);
        return { ok: true, message: undefined };
    }
    catch {
        return {
            ok: false,
            message: "PowerShell is not available. PowerShell is required to use the Windows Credential Vault. Install PowerShell from https://aka.ms/powershell",
        };
    }
}

//
// Checks that PowerShell is available, logging its version.
// Throws a helpful error if PowerShell is not found.
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
    await runCommand(["powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"]);
}

//
// Runs a PowerShell script and returns its trimmed stdout.
//
function runPowerShell(script: string): Promise<string> {
    return runCommand(["powershell", "-NoProfile", "-Command", script]);
}

//
// A vault implementation that persists secrets in the Windows Credential Vault
// using PowerShell and the Windows.Security.Credentials.PasswordVault API.
//
// Every secret name stored is prefixed with "psi-" to make photosphere entries
// clearly identifiable.  Native listing means no index file is needed.
//
export class WindowsKeychainVault implements IVault {
    //
    // Retrieves a secret by name from the Windows Credential Vault.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        await checkTool();
        const keychainName = toKeychainName(name);
        const escapedService = KEYCHAIN_SERVICE.replace(/'/g, "''");
        const escapedAccount = keychainName.replace(/'/g, "''");
        const script = `
$vault = New-Object Windows.Security.Credentials.PasswordVault;
try {
    $cred = $vault.Retrieve('${escapedService}', '${escapedAccount}');
    $cred.RetrievePassword();
    Write-Output $cred.Password
} catch {
    exit 1
}
`.trim();
        let raw: string;
        try {
            raw = await runPowerShell(script);
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
    // Creates or overwrites a secret in the Windows Credential Vault.
    //
    async set(secret: ISecret): Promise<void> {
        await checkTool();
        const keychainName = toKeychainName(secret.name);
        const payload: IKeychainPayload = { type: secret.type, value: secret.value };
        const json = JSON.stringify(payload).replace(/'/g, "''");
        const escapedService = KEYCHAIN_SERVICE.replace(/'/g, "''");
        const escapedAccount = keychainName.replace(/'/g, "''");
        const script = `
$vault = New-Object Windows.Security.Credentials.PasswordVault;
try {
    $existing = $vault.Retrieve('${escapedService}', '${escapedAccount}');
    $vault.Remove($existing);
} catch {}
$cred = New-Object Windows.Security.Credentials.PasswordCredential('${escapedService}', '${escapedAccount}', '${json}');
$vault.Add($cred);
`.trim();
        await runPowerShell(script);
    }

    //
    // Returns all photosphere secrets from the Windows Credential Vault by
    // searching for entries under the photosphere resource.
    //
    async list(): Promise<ISecret[]> {
        await checkTool();
        const escapedService = KEYCHAIN_SERVICE.replace(/'/g, "''");
        const script = `
$vault = New-Object Windows.Security.Credentials.PasswordVault;
try {
    $creds = $vault.FindAllByResource('${escapedService}');
    foreach ($cred in $creds) {
        Write-Output $cred.UserName
    }
} catch {}
`.trim();
        let output: string;
        try {
            output = await runPowerShell(script);
        }
        catch {
            return [];
        }

        const secrets: ISecret[] = [];
        const lines = output.split("\n");
        for (const line of lines) {
            const keychainName = line.trim();
            if (keychainName.startsWith("psi-")) {
                const name = fromKeychainName(keychainName);
                const secret = await this.get(name);
                if (secret !== undefined) {
                    secrets.push(secret);
                }
            }
        }
        return secrets;
    }

    //
    // Deletes a secret from the Windows Credential Vault.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        await checkTool();
        const keychainName = toKeychainName(name);
        const escapedService = KEYCHAIN_SERVICE.replace(/'/g, "''");
        const escapedAccount = keychainName.replace(/'/g, "''");
        const script = `
$vault = New-Object Windows.Security.Credentials.PasswordVault;
try {
    $cred = $vault.Retrieve('${escapedService}', '${escapedAccount}');
    $vault.Remove($cred);
} catch {}
`.trim();
        await runPowerShell(script);
    }

    //
    // Checks that PowerShell is available and executable.
    // Returns ok=true on success, or ok=false with an error message on failure.
    //
    async checkPrereqs(): Promise<IPrereqCheckResult> {
        return checkPrereqsOnce();
    }
}
