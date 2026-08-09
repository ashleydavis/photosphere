import * as fs from "fs/promises";
import * as fsSync from "fs";
import * as os from "os";
import * as path from "path";
import { updateFileOptimistic } from "node-utils";
import { ISecret, IVault, IPrereqCheckResult } from "./vault";

//
// Default directory under which the plain-text vault stores its vault file.
//
export const DEFAULT_VAULT_DIR = path.join(os.homedir(), ".config", "photosphere", "vault");

//
// The name of the single file that holds every secret in the vault.
//
export const VAULT_FILE_NAME = "vault.json";

//
// Unix permission mode: owner read + write only (rw-------)
//
export const FILE_MODE = 0o600;

//
// Unix permission mode: owner read + write + execute only (rwx------)
// Execute is required on directories to allow listing and traversal.
//
export const DIR_MODE = 0o700;

//
// How many times an update reloads and re-applies its change when another writer
// published to the vault file first, before giving up and throwing.
//
export const UPDATE_RETRIES = 3;

//
// Ensures that a directory exists, creating it (and any missing ancestors)
// if it does not.  On platforms that support POSIX permissions the directory
// is created with mode 0o700 (owner-only access).
//
export async function ensureDir(dirPath: string): Promise<void> {
    await fs.mkdir(dirPath, { recursive: true, mode: DIR_MODE });
    // Apply the mode explicitly because the recursive flag may create
    // intermediate directories with the process umask rather than DIR_MODE.
    await fs.chmod(dirPath, DIR_MODE).catch(() => {
        // chmod is not supported on all platforms (e.g. Windows); ignore errors.
    });
}

//
// The path of the single file that holds every secret in a vault directory.
//
export function getVaultFilePath(vaultDir: string): string {
    return path.join(vaultDir, VAULT_FILE_NAME);
}

//
// Restricts a file to owner read + write.
//
export async function applyFileMode(filePath: string): Promise<void> {
    await fs.chmod(filePath, FILE_MODE).catch(() => {
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
// Reads every secret out of a vault directory's vault file.
// Returns an empty set when the file does not exist yet.  A file that exists but does not parse
// throws, because silently treating a corrupt vault as an empty one would hide the damage and
// then overwrite it.
//
export async function readVaultFile(vaultDir: string): Promise<IVaultFile> {
    let raw: string;
    try {
        raw = await fs.readFile(getVaultFilePath(vaultDir), "utf8");
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
// Applies a change to a vault directory's vault file. Every write goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateFileOptimistic
// takes an exclusive lock beside the file, re-checks the file has not moved before renaming the new
// contents into place, and re-runs the mutator against the fresh contents if it has. It also makes
// publishing atomic, so an interrupted write leaves the previous vault rather than a truncated one.
//
// The whole vault lives in one file, so the read-all/write-all pair this replaces lost secrets: two
// processes each adding a secret both read the same contents, and whichever wrote second dropped
// the other's secret. Two CLI invocations storing credentials at once is enough to hit that.
//
export async function updateVaultFile(vaultDir: string, mutator: (contents: IVaultFile) => void): Promise<void> {
    // The update takes its lock beside the file, so the directory has to exist first, and has to be
    // created here to get owner-only permissions rather than the default ones the update would use.
    await ensureDir(vaultDir);

    const filePath = getVaultFilePath(vaultDir);
    await updateFileOptimistic<IVaultFile>(filePath, {},
        contents => {
            mutator(contents);
            return contents;
        },
        raw => JSON.parse(raw) as IVaultFile,
        contents => JSON.stringify(contents, null, 2),
        UPDATE_RETRIES);

    // The update publishes by renaming a temp file into place, and that temp file is created with
    // the default permissions, so the mode has to be reapplied to the file it becomes. Nothing is
    // exposed in between: the owner-only directory above is what stops another user reading it.
    await applyFileMode(filePath);
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
    // Retrieves a secret by name.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        const contents = await readVaultFile(this.vaultDir);
        return contents[name];
    }

    //
    // Creates or overwrites a secret.
    //
    async set(secret: ISecret): Promise<void> {
        await updateVaultFile(this.vaultDir, contents => {
            contents[secret.name] = secret;
        });
    }

    //
    // Returns all secrets stored in the vault file.
    // Returns an empty array if the vault file does not yet exist.
    //
    async list(): Promise<ISecret[]> {
        const contents = await readVaultFile(this.vaultDir);
        return Object.values(contents);
    }

    //
    // Deletes a secret by name.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        const contents = await readVaultFile(this.vaultDir);
        if (contents[name] === undefined) {
            return;
        }

        await updateVaultFile(this.vaultDir, current => {
            delete current[name];
        });
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
