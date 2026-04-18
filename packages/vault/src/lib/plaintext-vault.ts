import * as fs from "fs/promises";
import * as fsSync from "fs";
import * as os from "os";
import * as path from "path";
import { ISecret, IVault } from "./vault";

//
// Default directory under which the plain-text vault stores its files.
//
const DEFAULT_VAULT_DIR = path.join(os.homedir(), ".config", "photosphere", "vault");

//
// The file extension used for each secret file.
//
const SECRET_FILE_EXTENSION = ".json";

//
// Encodes a secret name into a filename-safe string using percent-encoding.
// This ensures that names containing special characters, slashes, etc.
// are stored safely on every supported filesystem.
//
function encodeSecretName(name: string): string {
    return encodeURIComponent(name);
}

//
// Decodes a filename back into the original secret name.
//
function decodeSecretName(encoded: string): string {
    return decodeURIComponent(encoded);
}

//
// Returns the absolute path of the file that stores the given secret.
//
function secretFilePath(vaultDir: string, name: string): string {
    return path.join(vaultDir, encodeSecretName(name) + SECRET_FILE_EXTENSION);
}

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
// A vault implementation that persists secrets as plain-text JSON files
// under a directory on the local filesystem.
//
// Each secret is written to its own file named after the (percent-encoded)
// secret name with a ".json" extension.  By default the vault directory is
// ~/.config/vault, but a custom directory can be supplied to the constructor
// which makes the implementation straightforward to test in isolation.
//
// This vault type is intentionally unencrypted and is intended for
// development / low-security use cases, or as a reference implementation
// for building encrypted or remote-backed vault types.
//
export class PlaintextVault implements IVault {
    //
    // Absolute path to the directory where secret files are stored.
    //
    private readonly vaultDir: string;

    constructor(vaultDir: string = DEFAULT_VAULT_DIR) {
        this.vaultDir = vaultDir;
    }

    //
    // Retrieves a secret by name.
    // Returns undefined if no secret with that name exists.
    //
    async get(name: string): Promise<ISecret | undefined> {
        const filePath = secretFilePath(this.vaultDir, name);
        let raw: string;
        try {
            raw = await fs.readFile(filePath, "utf8");
        }
        catch (error: any) {
            if (error.code === "ENOENT") {
                return undefined;
            }
            throw error;
        }
        return JSON.parse(raw) as ISecret;
    }

    //
    // Creates or overwrites a secret.
    //
    async set(secret: ISecret): Promise<void> {
        await ensureDir(this.vaultDir);
        const filePath = secretFilePath(this.vaultDir, secret.name);
        await fs.writeFile(filePath, JSON.stringify(secret, null, 2), { encoding: "utf8", mode: FILE_MODE });
        // Apply the mode explicitly; writeFile with mode may be affected by the
        // process umask on some systems.
        await fs.chmod(filePath, FILE_MODE).catch(() => {
            // chmod is not supported on all platforms (e.g. Windows); ignore errors.
        });
    }

    //
    // Returns all secrets stored in the vault directory.
    // Returns an empty array if the vault directory does not yet exist.
    //
    async list(): Promise<ISecret[]> {
        let entries: string[];
        try {
            entries = await fs.readdir(this.vaultDir);
        }
        catch (error: any) {
            if (error.code === "ENOENT") {
                return [];
            }
            throw error;
        }

        const secrets: ISecret[] = [];
        for (const entry of entries) {
            if (!entry.endsWith(SECRET_FILE_EXTENSION)) {
                continue;
            }
            const encodedName = entry.slice(0, -SECRET_FILE_EXTENSION.length);
            const name = decodeSecretName(encodedName);
            const secret = await this.get(name);
            if (secret !== undefined) {
                secrets.push(secret);
            }
        }
        return secrets;
    }

    //
    // Deletes a secret by name.
    // Does nothing if the secret does not exist.
    //
    async delete(name: string): Promise<void> {
        const filePath = secretFilePath(this.vaultDir, name);
        try {
            await fs.unlink(filePath);
        }
        catch (error: any) {
            if (error.code !== "ENOENT") {
                throw error;
            }
        }
    }

    //
    // Returns true if the vault directory exists on disk.
    // Useful for checking whether the vault has been initialised.
    //
    exists(): boolean {
        return fsSync.existsSync(this.vaultDir);
    }
}
