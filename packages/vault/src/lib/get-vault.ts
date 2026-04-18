import { IVault } from "./vault";
import { PlaintextVault } from "./plaintext-vault";

//
// Cache of vault instances keyed by type string.
// getVault always returns the same instance for the same type.
//
const vaultInstances = new Map<string, IVault>();

//
// Returns the vault instance for the given type string, creating it on first
// call and reusing it on subsequent calls.
//
// Supported types:
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
        return new PlaintextVault();
    }
    throw new Error(`Unknown vault type: "${type}". Supported types: "plaintext".`);
}
