import { IVault } from "./vault";
import { PlaintextVault } from "./plaintext-vault";
import { MacOSKeychainVault } from "./macos-keychain-vault";
import { LinuxKeychainVault } from "./linux-keychain-vault";
import { WindowsKeychainVault } from "./windows-keychain-vault";

//
// Cache of vault instances keyed by type string.
// getVault always returns the same instance for the same type.
//
const vaultInstances = new Map<string, IVault>();

//
// Returns the default vault type from the PHOTOSPHERE_VAULT_TYPE environment
// variable, falling back to "keychain" when the variable is not set.
//
export function getDefaultVaultType(): string {
    return process.env.PHOTOSPHERE_VAULT_TYPE ?? "keychain";
}

//
// Returns the vault instance for the given type string, creating it on first
// call and reusing it on subsequent calls.
//
// Supported types:
//   "keychain"  — stores secrets in the OS keychain (macOS, Linux, Windows)
//   "plaintext" — stores secrets as plain-text JSON files under ~/.config/vault
//
// Throws if the type is not recognised.
//
export function getVault(type: string): IVault {
    const existing = vaultInstances.get(type);
    if (existing !== undefined) {
        return existing;
    }

    const vault = instantiateVault(type);
    vaultInstances.set(type, vault);
    return vault;
}

//
// Creates a new vault instance for the given type.
//
function instantiateVault(type: string): IVault {
    if (type === "plaintext") {
        const vaultDir = process.env.PHOTOSPHERE_VAULT_DIR;
        return vaultDir ? new PlaintextVault(vaultDir) : new PlaintextVault();
    }
    if (type === "keychain") {
        if (process.platform === "darwin") {
            return new MacOSKeychainVault();
        }
        if (process.platform === "linux") {
            return new LinuxKeychainVault();
        }
        if (process.platform === "win32") {
            return new WindowsKeychainVault();
        }
        throw new Error(`Keychain vault is not supported on platform "${process.platform}".`);
    }
    throw new Error(`Unknown vault type: "${type}". Supported types: "keychain", "plaintext".`);
}
