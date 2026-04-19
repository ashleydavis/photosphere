import type { IElectronAPI, IVaultSecret } from 'electron-defs';

//
// Implements vault operations in the renderer process by forwarding each call to
// the main process via Electron IPC.  Callers can use this wherever an IVault-like
// object is needed without importing the Node-only `vault` package.
//
export class ProxyVault {
    constructor(private readonly electronAPI: IElectronAPI) {}

    //
    // Retrieves a secret by name; returns undefined if it does not exist.
    //
    async get(name: string): Promise<IVaultSecret | undefined> {
        return await this.electronAPI.vaultGet(name);
    }

    //
    // Creates or overwrites a secret.
    //
    async set(secret: IVaultSecret): Promise<void> {
        await this.electronAPI.vaultSet(secret);
    }

    //
    // Deletes a secret by name; does nothing if it does not exist.
    //
    async delete(name: string): Promise<void> {
        await this.electronAPI.vaultDelete(name);
    }

    //
    // Returns all secrets stored in the vault.
    //
    async list(): Promise<IVaultSecret[]> {
        return await this.electronAPI.vaultList();
    }
}
