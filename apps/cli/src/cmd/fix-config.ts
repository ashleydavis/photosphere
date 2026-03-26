//
// Decrypts .db/config.json in place if it was accidentally encrypted.
//

import { createStorage, loadEncryptionKeys } from "storage";
import pc from "picocolors";
import { log } from "utils";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from "../lib/config";
import { resolveKeyPaths, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export interface IFixConfigCommandOptions extends IBaseCommandOptions {
    //
    // Encryption key file(s) used to decrypt the config.
    //
    key?: string;
}

const CONFIG_PATH = ".db/config.json";

//
// Command that decrypts .db/config.json in place if it was accidentally encrypted.
//
export async function fixConfigCommand(context: ICommandContext, options: IFixConfigCommandOptions): Promise<void> {
    const { yes } = options;
    const nonInteractive = yes ?? false;

    const dbDir = options.db;
    if (!dbDir) {
        log.error(pc.red("✗ Database directory is required (--db)."));
        await exit(1);
        return;
    }

    if (dbDir.startsWith("s3:")) {
        await configureIfNeeded(["s3"], nonInteractive);
    }

    const s3Config = await getS3Config();

    const keyPaths = await resolveKeyPaths(options.key);
    if (keyPaths.length === 0) {
        log.error(pc.red("✗ Decryption requires --key."));
        await exit(1);
        return;
    }

    const { options: readStorageOptions } = await loadEncryptionKeys(keyPaths, false);

    const { storage: rawStorage } = createStorage(dbDir, s3Config, undefined);
    const { storage: readStorage } = createStorage(dbDir, s3Config, readStorageOptions);

    if (!await rawStorage.fileExists(CONFIG_PATH)) {
        log.info(pc.yellow(`⚠️  No config file found at ${CONFIG_PATH}.`));
        await exit(0);
        return;
    }

    const data = await readStorage.read(CONFIG_PATH);
    if (!data) {
        log.error(pc.red(`✗ Failed to read ${CONFIG_PATH}.`));
        await exit(1);
        return;
    }

    const text = data.toString("utf8");

    try {
        JSON.parse(text);
    }
    catch (err) {
        log.error(pc.red(`✗ Config file could not be decrypted or is not valid JSON: ${(err as Error).message}`));
        await exit(1);
        return;
    }

    await rawStorage.write(CONFIG_PATH, "application/json", Buffer.from(text, "utf8"));

    log.info(pc.green(`✅ Config file decrypted successfully.`));
    await exit(0);
}
