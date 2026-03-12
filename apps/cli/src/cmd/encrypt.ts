//
// In-place encrypt: transform the database at --db so that all files are encrypted
// (plain → encrypted, re-encrypt with new key, or old-format → new format).
//

import { Readable } from "stream";
import * as fs from "fs/promises";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { pathExists, copy } from "node-utils";
import pc from "picocolors";
import { log } from "utils";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from "../lib/config";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { resolveKeyPaths, IBaseCommandOptions, ICommandContext, promptForKeyGenerationPath } from "../lib/init-cmd";
import { writeProgress, clearProgressMessage } from "../lib/terminal-utils";
import { confirm, isCancel } from "../lib/clack/prompts";
import { merkleTreeExists, encrypt as apiEncrypt } from "api";

export interface IEncryptCommandOptions extends IBaseCommandOptions {
    //
    // Encryption key file(s) (comma-separated list).
    // First key is the default key used for writing and for reading legacy-format files.
    //
    key?: string;

    //
    // Generate encryption key(s) if they do not exist.
    //
    generateKey?: boolean;
}

//
// Encrypts the database at --db in place (plain → encrypted, re-encrypt, or old → new format).
//
export async function encryptCommand(context: ICommandContext, options: IEncryptCommandOptions): Promise<void> {
    const { verbose, yes, cwd } = options;
    const nonInteractive = yes ?? false;

    let dbDir: string | undefined = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, cwd ?? process.cwd());
    }
    if (!dbDir) {
        log.error(pc.red("✗ Database directory is required (--db)."));
        await exit(1);
    }

    if (dbDir.startsWith("s3:")) {
        await configureIfNeeded(["s3"], nonInteractive);
    }

    const s3Config = await getS3Config();

    //
    // Key handling:
    // - In non-interactive mode we still require --key explicitly.
    // - In interactive mode, if --generate-key is set but no --key was provided,
    //   prompt the user for a key path (mirroring init behavior).
    //
    if (!nonInteractive && options.generateKey && !options.key) {
        const result = await promptForKeyGenerationPath();
        if (result.keyPath) {
            options.key = result.keyPath;
            options.generateKey = result.generateKey;
        }
    }

    const resolvedKeyPaths = await resolveKeyPaths(options.key);
    if (resolvedKeyPaths.length === 0) {
        log.error(pc.red(`✗ Encryption requires --key (comma-separated list supported).`));
        await exit(1);
    }

    const { options: writeStorageOptions, isEncrypted: writeIsEncrypted } = await loadEncryptionKeys(
        resolvedKeyPaths,
        options.generateKey ?? false
    );
    if (!writeIsEncrypted) {
        log.error(pc.red(`✗ Failed to load or generate encryption key(s).`));
        await exit(1);
    }

    const { storage: plainStorage } = createStorage(dbDir, s3Config, undefined);
    const hasTree = await merkleTreeExists(plainStorage);
    if (!hasTree) {
        log.error(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}`));
        await exit(1);
    }

    const hasEncryptionPub = await plainStorage.fileExists(".db/encryption.pub");
    const { storage: readStorage } = hasEncryptionPub
        ? createStorage(dbDir, s3Config, writeStorageOptions)
        : { storage: plainStorage };
    const { storage: writeStorage } = createStorage(dbDir, s3Config, writeStorageOptions);

    if (!nonInteractive) {
        log.warn(pc.yellow(`⚠️  This will encrypt the database in place at ${pc.cyan(dbDir)}.`));
        log.warn(pc.yellow(`    All files will be rewritten in encrypted form. This cannot be undone without the key.`));
        const confirmed = await confirm({ message: "Proceed with encryption?", initialValue: false });
        if (isCancel(confirmed) || !confirmed) {
            log.info("Encryption cancelled.");
            await exit(0);
            return;
        }
    }

    log.info(pc.blue("Encrypting database in place..."));
    writeProgress("Encrypting files...");

    await apiEncrypt(readStorage, writeStorage, (msg) => writeProgress(msg));

    clearProgressMessage();

    // Only after the entire database has been re-encrypted: store the new public key in .db (plain marker file).
    const publicKeySource = `${resolvedKeyPaths[0]}.pub`;
    const metaPath = pathJoin(dbDir, ".db");
    const encryptionPubDest = pathJoin(metaPath, "encryption.pub");

    if (dbDir.startsWith("s3:")) {
        const { storage: plainStorage } = createStorage(dbDir, s3Config, undefined);
        const content = await fs.readFile(publicKeySource);
        await plainStorage.writeStream(".db/encryption.pub", "application/octet-stream", Readable.from(content));
    }
    else {
        if (await pathExists(publicKeySource)) {
            await copy(publicKeySource, encryptionPubDest);
            log.info(pc.green("✓ Wrote .db/encryption.pub"));
        }
        else {
            log.warn(pc.yellow(`⚠️ Public key file not found: ${publicKeySource}`));
        }
    }

    log.info("");
    log.info(pc.green("✅ Database encrypted in place successfully"));
    await exit(0);
}
