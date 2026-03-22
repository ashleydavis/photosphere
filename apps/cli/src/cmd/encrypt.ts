//
// In-place encrypt: transform the database at --db so that all files are encrypted
// (plain → encrypted, re-encrypt with new key, or old-format → new format).
//

import { createStorage, exportPublicKeyToPem, loadEncryptionKeys } from "storage";
import pc from "picocolors";
import { log } from "utils";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from "../lib/config";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { resolveKeyPaths, IBaseCommandOptions, ICommandContext, promptForKeyGenerationPath } from "../lib/init-cmd";
import { writeProgress, clearProgressMessage } from "../lib/terminal-utils";
import { confirm, isCancel } from "../lib/clack/prompts";
import { merkleTreeExists, encrypt as apiEncrypt } from "api";
import { configureLog } from "../lib/log";

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

    await configureLog({ verbose });

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

    const { storage: rawStorage } = createStorage(dbDir, s3Config, undefined);
    const hasTree = await merkleTreeExists(rawStorage);
    if (!hasTree) {
        log.error(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}`));
        await exit(1);
    }

    const { storage: readStorage } = createStorage(dbDir, s3Config, writeStorageOptions);
    const { storage: writeStorage } = createStorage(dbDir, s3Config, writeStorageOptions);

    if (nonInteractive) {
        if (!yes) {
            log.error(pc.red("✗ Non interactive encryption requires --yes to proceed."));
            await exit(1);
        }
    }
    else {
        log.warn(pc.yellow(`⚠️  This will encrypt the database in place at ${pc.cyan(dbDir)}.`));
        log.warn(pc.yellow(`   All files will be rewritten in encrypted form. This cannot be undone without the key.`));
        const confirmed = await confirm({ message: "Proceed with encryption?", initialValue: false });
        if (isCancel(confirmed) || !confirmed) {
            log.info("Encryption cancelled.");
            await exit(0);
            return;
        }
    }

    writeProgress("Encrypting files...");

    const { encrypted, skipped } = await apiEncrypt(readStorage, writeStorage, (msg) => writeProgress(msg), writeStorageOptions.encryptionPublicKey!, rawStorage);

    clearProgressMessage();

    // Only after the entire database has been re-encrypted: write the public key to .db/encryption.pub.
    const publicKeyPem = exportPublicKeyToPem(writeStorageOptions.encryptionPublicKey!);
    await rawStorage.write(".db/encryption.pub", undefined, Buffer.from(publicKeyPem, "utf8"));

    log.info("");
    log.info(pc.green(`✅ Encrypted ${encrypted} files, ${skipped} were already encrypted.`));
    await exit(0);
}
