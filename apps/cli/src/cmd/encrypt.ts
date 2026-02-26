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
import { resolveKeyPaths, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { writeProgress, clearProgressMessage } from "../lib/terminal-utils";
import { confirm, isCancel } from "../lib/clack/prompts";
import { merkleTreeExists, encrypt as apiEncrypt } from "api";

export interface IEncryptCommandOptions extends IBaseCommandOptions {
    //
    // Destination encryption key file(s) (comma-separated list).
    // First key is the write key; must match .db/encryption.pub after encrypt.
    //
    key?: string;

    //
    // Source encryption key file(s) for reading an already-encrypted database.
    // When omitted, the source is treated as plain.
    //
    sourceKey?: string;

    //
    // Generate destination encryption key if it does not exist.
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

    // Read storage: plain if no sourceKey, else encrypted with sourceKey
    const resolvedSourceKeyPaths = await resolveKeyPaths(options.sourceKey);
    const readOptions = resolvedSourceKeyPaths.length > 0
        ? (await loadEncryptionKeys(resolvedSourceKeyPaths, false)).options
        : undefined;
    const { storage: readStorage } = createStorage(dbDir, s3Config, readOptions);

    const hasTree = await merkleTreeExists(readStorage);
    if (!hasTree) {
        log.error(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}`));
        await exit(1);
    }

    // When source is encrypted we expect .db/encryption.pub
    if (resolvedSourceKeyPaths.length > 0) {
        const hasEncryptionPub = await readStorage.fileExists(".db/encryption.pub");
        if (!hasEncryptionPub) {
            log.error(pc.red(`✗ Database at ${pc.cyan(dbDir)} does not appear to be encrypted (no .db/encryption.pub). Omit --source-key for a plain database.`));
            await exit(1);
        }
    }
    else {
        const hasEncryptionPub = await readStorage.fileExists(".db/encryption.pub");
        if (hasEncryptionPub) {
            log.error(pc.red(`✗ Database at ${pc.cyan(dbDir)} is already encrypted. Use --source-key to re-encrypt or convert format.`));
            await exit(1);
        }
    }

    const resolvedDestKeyPaths = await resolveKeyPaths(options.key);
    if (resolvedDestKeyPaths.length === 0) {
        log.error(pc.red(`✗ Encryption requires --key (destination key for encrypting the database).`));
        await exit(1);
    }

    const { options: writeStorageOptions, isEncrypted: writeIsEncrypted } = await loadEncryptionKeys(
        resolvedDestKeyPaths,
        options.generateKey ?? false
    );
    if (!writeIsEncrypted) {
        log.error(pc.red(`✗ Failed to load or generate encryption key for destination.`));
        await exit(1);
    }

    const { storage: writeStorage } = createStorage(dbDir, s3Config, writeStorageOptions);

    // Re-encrypting with the same key: nothing to do; exit early. Do not overwrite .db/encryption.pub.
    if (resolvedSourceKeyPaths.length > 0 && resolvedSourceKeyPaths[0] === resolvedDestKeyPaths[0]) {
        log.info(pc.blue("Database is already encrypted with this key; nothing to do."));
        log.info("");
        log.info(pc.green("✅ Done"));
        await exit(0);
        return;
    }

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
    const publicKeySource = `${resolvedDestKeyPaths[0]}.pub`;
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
