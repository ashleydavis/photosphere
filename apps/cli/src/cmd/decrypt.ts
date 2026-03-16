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
import { decrypt as apiDecrypt } from "api";
import { configureLog } from "../lib/log";

export interface IDecryptCommandOptions extends IBaseCommandOptions {
    //
    // Encryption key file(s) used to read the source database (comma-separated).
    //
    key?: string;
}

//
// Decrypts the database at --db in place (encrypted → plain). Removes .db/encryption.pub.
//
export async function decryptCommand(context: ICommandContext, options: IDecryptCommandOptions): Promise<void> {
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

    const keyPaths = await resolveKeyPaths(options.key);
    if (keyPaths.length === 0) {
        log.error(pc.red(`✗ Decryption requires --key (comma-separated list supported).`));
        await exit(1);
    }

    const { options: readStorageOptions } = await loadEncryptionKeys(keyPaths, false);

    const { storage: rawStorage } = createStorage(dbDir, s3Config, undefined);
    const hasEncryptionPub = await rawStorage.fileExists(".db/encryption.pub");
    if (!hasEncryptionPub) {
        log.error(pc.red(`✗ Database at ${pc.cyan(dbDir)} does not appear to be encrypted (no .db/encryption.pub).`));
        await exit(1);
    }

    const { storage: readStorage } = createStorage(dbDir, s3Config, readStorageOptions);

    if (nonInteractive) {
        if (!yes) {
            log.error(pc.red("✗ Non interactive decryption requires --yes to proceed."));
            await exit(1);
        }
    }
    else {
        log.warn(pc.yellow(`⚠️  This will decrypt the database in place at ${pc.cyan(dbDir)}.`));
        log.warn(pc.yellow(`    All files will be rewritten in plain form. The database will no longer be encrypted.`));
        const confirmed = await confirm({ message: "Proceed with decryption?", initialValue: false });
        if (isCancel(confirmed) || !confirmed) {
            log.info("Decryption cancelled.");
            await exit(0);
            return;
        }
    }

    writeProgress("Decrypting files...");

    const { decrypted, skipped } = await apiDecrypt(readStorage, rawStorage, (msg) => writeProgress(msg), rawStorage);

    clearProgressMessage();

    await rawStorage.deleteFile(".db/encryption.pub");

    log.info("");
    log.info(pc.green(`✅ Decrypted ${decrypted} files, ${skipped} were already plain.`));
    await exit(0);
}
