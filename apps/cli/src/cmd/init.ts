import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";
import { confirm, text, isCancel, outro } from '@clack/prompts';
import { pickDirectory } from "../lib/directory-picker";
import { resolve, join } from "path";
import { existsSync } from "fs";

export interface IInitCommandOptions extends ICreateCommandOptions {
}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(options: IInitCommandOptions): Promise<void> {

    // Ask about encryption key generation if not already specified
    if (!options.key && !options.yes) {
        const generateKey = await confirm({
            message: 'Would you like to generate an encryption key for your database?',
            initialValue: false,
        });

        if (isCancel(generateKey)) {
            await exit(1);
        }

        if (generateKey) {
            // Ask for directory
            const keyDir = await pickDirectory(
                'Select directory to save encryption key:',
                process.cwd(),
                (path) => {
                    if (!existsSync(path)) {
                        return 'Directory does not exist';
                    }
                    return true;
                }
            );

            if (!keyDir) {
                outro(pc.red('No directory selected for encryption key'));
                await exit(1);
            }

            // Ask for filename
            const keyFilename = await text({
                message: 'Enter filename for encryption key:',
                placeholder: 'photosphere.key',
                initialValue: 'photosphere.key',
                validate: (value) => {
                    if (!value || value.trim().length === 0) {
                        return 'Filename is required';
                    }
                    // Check for invalid characters
                    if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
                        return 'Filename can only contain letters, numbers, dots, hyphens, and underscores';
                    }
                    // Check if file already exists
                    const keyPath = join(keyDir!, value);
                    if (existsSync(keyPath)) {
                        return 'File already exists';
                    }
                    return undefined;
                },
            });

            if (isCancel(keyFilename)) {
                await exit(1);
            }

            // Set the key path and enable generation
            options.key = join(keyDir!, keyFilename as string);
            options.generateKey = true;

            log.info('');
            log.info(pc.green(`✓ Encryption key will be generated and saved to: ${options.key}`));
            log.info(pc.yellow(`⚠️  Keep this key file safe! You will need it to access your encrypted database.`));
            log.info('');
        }
    }

    await createDatabase(options.db, options, false, true);

    const displayPath = (options.db === "." || options.db === "./") ? "current directory" : options.db;
    const isCurrentDir = options.db === "." || options.db === "./";

    log.info('');
    log.info(pc.green(`✓ Created new media file database in ${isCurrentDir ? "the " : "\""}${displayPath}${isCurrentDir ? "" : "\""}"`));
    
    if (options.generateKey && options.key) {
        log.info(pc.green(`✓ Encryption key saved to: ${options.key}`));
        log.info(pc.green(`✓ Public key saved to: ${options.key}.pub`));
    }
    
    log.info('');
    log.info(pc.dim('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.dim('To get started:'));
    if (isCurrentDir) {
        log.info(pc.dim(`  1. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    } else {
        log.info(pc.dim(`  1. ${pc.cyan(`cd ${options.db}`)} (change to your database directory)`));
        log.info(pc.dim(`  2. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(pc.dim(`Or identify the database using the path: ${pc.cyan(`psi add --db ${options.db} <source-media-directory>`)}`));
    }

    if (options.key) {
        log.info('');
        log.info(pc.dim('When using your encrypted database, specify the key file:'));
        log.info(pc.dim(`  ${pc.cyan(`psi add --key ${options.key} <source-media-directory>`)}`));
    }

    await exit(0);
}