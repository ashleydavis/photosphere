import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { createDatabase, ICreateCommandOptions } from "../lib/init-cmd";
import { confirm, text, isCancel, outro, select } from '@clack/prompts';
import { pickDirectory } from "../lib/directory-picker";
import { resolve, join } from "path";
import { existsSync } from "fs";

export interface IInitCommandOptions extends ICreateCommandOptions {
}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(options: IInitCommandOptions): Promise<void> {

    // Ask about encryption if not already specified
    if (!options.key && !options.yes) {
        const wantEncryption = await confirm({
            message: 'Would you like to encrypt your database? (You can say no now and create an encrypted copy later using the replicate command)',
            initialValue: false,
        });

        if (isCancel(wantEncryption)) {
            await exit(1);
        }

        if (wantEncryption) {
            log.info('');
            log.info(pc.yellow('⚠️  To encrypt your database you need a private key that you will have to keep safe and not lose'));
            log.info(pc.yellow('   (otherwise you\'ll lose access to your encrypted database)'));
            log.info('');
            
            // Ask how they want to handle the key
            const keyChoice = await select({
                message: 'How would you like to handle the encryption key?',
                options: [
                    { value: 'existing', label: 'Use an existing private key' },
                    { value: 'generate', label: 'Generate a new key and save it to a file' },
                ],
            });

            if (isCancel(keyChoice)) {
                await exit(1);
            }

            if (keyChoice === 'existing') {
                // Ask for existing key file
                const keyDir = await pickDirectory(
                    'Select directory containing your encryption key:',
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
                    message: 'Enter the encryption key filename:',
                    placeholder: 'photosphere.key',
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Filename is required';
                        }
                        // Check if file exists
                        const keyPath = join(keyDir!, value);
                        if (!existsSync(keyPath)) {
                            return 'File does not exist';
                        }
                        // Check if public key exists
                        const publicKeyPath = `${keyPath}.pub`;
                        if (!existsSync(publicKeyPath)) {
                            return 'Public key file (.pub) not found alongside private key';
                        }
                        return undefined;
                    },
                });

                if (isCancel(keyFilename)) {
                    await exit(1);
                }

                // Set the key path (no generation needed)
                options.key = join(keyDir!, keyFilename as string);
                options.generateKey = false;

                log.info('');
                log.info(pc.green(`✓ Using existing encryption key: ${options.key}`));
                log.info('');
            } else if (keyChoice === 'generate') {
                // Generate new key
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
    }

    await createDatabase(options.db, options);

    const displayPath = (options.db === "." || options.db === "./") ? "current directory" : options.db;
    const isCurrentDir = options.db === "." || options.db === "./";

    log.info('');
    log.info(pc.green(`✓ Created new media file database in ${isCurrentDir ? "the " : "\""}${displayPath}${isCurrentDir ? "" : "\""}"`));
    
    if (options.generateKey && options.key) {
        log.info(pc.green(`✓ Encryption key saved to: ${options.key}`));
        log.info(pc.green(`✓ Public key saved to: ${options.key}.pub`));
    }
    
    log.info('');
    log.info(pc.blue('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.blue('To get started:'));
    if (isCurrentDir) {
        log.info(pc.blue(`  1. `) + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    } else {
        log.info(pc.blue(`  1. `) + pc.cyan(`cd ${options.db}`) + pc.blue(` (change to your database directory)`));
        log.info(pc.blue(`  2. `) + pc.cyan(`psi add <source-media-directory>`) + pc.blue(` (add your photos and videos)`));
    }
    log.info('');
    if (!isCurrentDir) {
        log.info(pc.blue(`Or identify the database using the path: `) + pc.cyan(`psi add --db ${options.db} <source-media-directory>`));
    }

    if (options.key) {
        log.info('');
        log.info(pc.blue('When using your encrypted database, specify the key file:'));
        log.info(pc.blue(`  `) + pc.cyan(`psi add --key ${options.key} <source-media-directory>`));
    }

    await exit(0);
}