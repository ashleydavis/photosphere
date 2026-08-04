import * as fs from "fs/promises";
import * as fsSync from "fs";
import * as os from "os";
import * as path from "path";
import { ISecret, IVault, IPrereqCheckResult } from "./vault";

//
// Default directory under which the plain-text vault stores its vault file.
//
const DEFAULT_VAULT_DIR = path.join(os.homedir(), ".config", "photosphere", "vault");

//
// The name of the single file that holds every secret in the vault.
//
const VAULT_FILE_NAME = "vault.json";

//
// Unix permission mode: owner read + write only (rw-------)
//
const FILE_MODE = 0o600;

//
// Unix permission mode: owner read + write + execute only (rwx------)
// Execute is required on directories to allow listing and traversal.
//
const DIR_MODE = 0o700;

//
// Ensures that a directory exists, creating it (and any missing ancestors)
// if it does not.  On platforms that support POSIX permissions the directory
// is created with mode 0o700 (owner-only access).
//
async function ensureDir(dirPath: string): Promise<void> {
    await fs.mkdir(dirPath, { recursive: true, mode: DIR_MODE });
    // Apply the mode explicitly because the recursive flag may create
    // intermediate directories with the process umask rather than DIR_MODE.
    await fs.chmod(dirPath, DIR_MODE).catch(() => {
        // chmod is not supported on all platforms (e.g. Windows); ignore errors.
    });
}

//
// The on-disk shape of the vault file: a JSON object whose keys are secret
// names and whose values are the secrets stored under those names.  A secret
// name lives in a JSON key, so a colon, slash or unicode character in a name
// needs no encoding of any kind.
//
export interface IVaultFile {
    //
    // Each secret, keyed by its name.
    //
    [name: string]: ISecret;
}

//
// A vault implementation that persists secrets as a single plain-text JSON
// file under a directory on the local filesystem.
//
// Every secret is held in one "vault.json" file, keyed by secret name.  By
// default the vault directory is ~/.config/vault, but a custom directory can
// be supplied to the constructor which makes the implementation
// straightforward to test in isolation.
//
// This vault type is intentionally unencrypted and is intended for
// development / low-security use cases, or as a reference implementation
// for building encrypted or remote-backed vault types.
//
export class PlaintextVault implements IVault {
    //
    // Absolute path to the directory that holds the vault file.
    //
    private readonly vaultDir: string;

    //
    // Absolute path to the single file that holds every secret.
    //
    private readonly vaultFilePath: string;

    constructor(vaultDir: string = DEFAULT_VAULT_DIR) {
        this.vaultDir = vaultDir;
        this.vaultFilePath = path.join(vaultDir, VAULT_FILE_NAME);
    }

    //
    // Reads every secret out of the vault file.
    // Returns an empty set when the file does not exist yet.  A file that
    // exists but does not parse throws, because silently treating a corrupt
    // vault as an empty one would hide the damage and then overwrite it.
    //
    private async readAll(): Promise<IVaultFile> {
        let raw: string;
        try {
            raw = await fs.readFile(this.vaultFilePath, "utf8");
        }
        catch (error: any) {
            if (error.code === "ENOENT") {
                return {};
            }
            throw error;
        }
        return JSON.parse(raw) as IVaultFile;
    }

    //
    // Writes every secret back to the vault file, creating the vault
    // directory first if it is not there.
    //
    private async writeAll(contents: IVaultFile): Promise<void> {
        await ensureDir(this.vaultDir);
        await fs.writeFile(this.vaultFilePath, JSON.stringify(contents, null, 2), { encoding: "utf8", mode: FILE_MODE });
        // Apply the mode explicitly; writeFile with mode may be affected by the
        // process umask on some systems.
        await fs.chmod(this.vaultFilePath, FILE_MODE).catch(() => {
            // chmod is not supported on all platforms (e.g. Windows); ignore errors.
        });
    }

    //
    // Retrieves a secret by name.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        const contents = await this.readAll();
        return contents[name];
    }

    //
    // Creates or overwrites a secret.
    //
    async set(secret: ISecret): Promise<void> {
        const contents = await this.readAll();
        contents[secret.name] = secret;
        await this.writeAll(contents);
    }

    //
    // Returns all secrets stored in the vault file.
    // Returns an empty array if the vault file does not yet exist.
    //
    async list(): Promise<ISecret[]> {
        const contents = await this.readAll();
        return Object.values(contents);
    }

    //
    // Deletes a secret by name.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        const contents = await this.readAll();
        if (contents[name] === undefined) {
            return;
        }
        delete contents[name];
        await this.writeAll(contents);
    }

    //
    // Returns true if the vault file exists on disk.
    // Useful for checking whether the vault has been initialised.
    //
    exists(): boolean {
        return fsSync.existsSync(this.vaultFilePath);
    }

    //
    // The plaintext vault has no external tool dependencies.
    //
    async checkPrereqs(): Promise<IPrereqCheckResult> {
        return { ok: true, message: undefined };
    }
}
