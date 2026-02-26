//
// In-place decrypt: transform the database at --db so that all files are plain
// (encrypted → plain). Removes .db/encryption.pub at the end.
//

import { createStorage, loadEncryptionKeys } from "storage";
import pc from "picocolors";
import { log } from "utils";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from "../lib/config";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { resolveKeyPaths, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { writeProgress, clearProgressMessage } from "../lib/terminal-utils";
import { confirm, isCancel } from "../lib/clack/prompts";
import { merkleTreeExists, decrypt as apiDecrypt } from "api";

export interface IDecryptCommandOptions extends IBaseCommandOptions {
    //
    // Primary encryption key file(s) used to read the source database (comma-separated).
    //
    key?: string;

    //
    // Optional additional source key file(s); merged with --key for the key map.
    //
    sourceKey?: string;
}

//
// Decrypts the database at --db in place (encrypted → plain). Removes .db/encryption.pub.
//
export async function decryptCommand(context: ICommandContext, options: IDecryptCommandOptions): Promise<void> {
    const { yes, cwd } = options;
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

    const keyPaths = await resolveKeyPaths(options.key);
    const sourceKeyPaths = await resolveKeyPaths(options.sourceKey);
    const allKeyPaths = keyPaths.length > 0 ? [...keyPaths, ...sourceKeyPaths] : [...sourceKeyPaths];

    if (allKeyPaths.length === 0) {
        log.error(pc.red(`✗ Decryption requires --key (and optionally --source-key) to read the encrypted database.`));
        await exit(1);
    }

    const { options: readStorageOptions } = await loadEncryptionKeys(allKeyPaths, false);
    const { storage: readStorage } = createStorage(dbDir, s3Config, readStorageOptions);

    const hasTree = await merkleTreeExists(readStorage);
    if (!hasTree) {
        log.error(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}`));
        await exit(1);
    }

    const hasEncryptionPub = await readStorage.fileExists(".db/encryption.pub");
    if (!hasEncryptionPub) {
        log.error(pc.red(`✗ Database at ${pc.cyan(dbDir)} does not appear to be encrypted (no .db/encryption.pub).`));
        await exit(1);
    }

    const { storage: writeStorage } = createStorage(dbDir, s3Config, undefined);

    if (!nonInteractive) {
        log.warn(pc.yellow(`⚠️  This will decrypt the database in place at ${pc.cyan(dbDir)}.`));
        log.warn(pc.yellow(`    All files will be rewritten in plain form. The database will no longer be encrypted.`));
        const confirmed = await confirm({ message: "Proceed with decryption?", initialValue: false });
        if (isCancel(confirmed) || !confirmed) {
            log.info("Decryption cancelled.");
            await exit(0);
            return;
        }
    }

    log.info(pc.blue("Decrypting database in place..."));
    writeProgress("Decrypting files...");

    await apiDecrypt(readStorage, writeStorage, (msg) => writeProgress(msg));

    clearProgressMessage();

    await writeStorage.deleteFile(".db/encryption.pub");
    log.info(pc.green("✓ Removed .db/encryption.pub"));

    log.info("");
    log.info(pc.green("✅ Database decrypted in place successfully"));
    await exit(0);
}
