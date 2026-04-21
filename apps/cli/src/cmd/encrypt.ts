//
// In-place encrypt: transform the database at --db so that all files are encrypted
// (plain → encrypted, re-encrypt with new key, or old-format → new format).
//

import { createStorage, exportPublicKeyToPem, loadEncryptionKeysFromPem, generateKeyPair } from "storage";
import pc from "picocolors";
import { log } from "utils";
import { exit } from "node-utils";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { resolveKeyPems, IBaseCommandOptions, ICommandContext, promptForEncryption, selectEncryptionKey, configureS3IfNeeded, getDefaultS3Config } from "../lib/init-cmd";
import { getVault, getDefaultVaultType } from "vault";
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
        await configureS3IfNeeded(nonInteractive);
    }

    const s3Config = await getDefaultS3Config();

    //
    // Key handling:
    // - In non-interactive mode we still require --key explicitly.
    // - In interactive mode, if --generate-key is set but no --key was provided,
    //   prompt the user for a key path (mirroring init behavior).
    //
    if (!nonInteractive && !options.key) {
        const result = await promptForEncryption('Select the encryption key to use:');
        if (result.keyName) {
            options.key = result.keyName;
        }
        else {
            const selectedKey = await selectEncryptionKey('Select an encryption key:');
            options.key = selectedKey;
        }
    }

    // If --generate-key is set, generate the first key in the list if it doesn't exist in the vault.
    if (options.generateKey && options.key) {
        const firstKeyName = options.key.split(',')[0].trim();
        const vault = getVault(getDefaultVaultType());
        const existing = await vault.get(`cli:encryption:${firstKeyName}`);
        if (!existing) {
            const keyPair = generateKeyPair();
            const privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
            const publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);
            await vault.set({
                name: `cli:encryption:${firstKeyName}`,
                type: 'encryption-key',
                value: JSON.stringify({ privateKeyPem, publicKeyPem }),
            });
        }
    }

    const keyPems = await resolveKeyPems(options.key);
    if (keyPems.length === 0) {
        log.error(pc.red(`✗ Encryption requires --key.`));
        await exit(1);
    }

    const { options: writeStorageOptions, isEncrypted: writeIsEncrypted } = await loadEncryptionKeysFromPem(keyPems);
    if (!writeIsEncrypted) {
        log.error(pc.red(`✗ Failed to load encryption key.`));
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
        log.warn(pc.yellow(`⚠️  This will encrypt the database in place at ${pc.cyan(dbDir)} using key: ${pc.cyan(options.key ?? "")}.`));
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
