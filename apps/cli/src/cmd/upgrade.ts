import { log, retry } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, loadDatabase, ICommandContext, resolveKeyPath } from "../lib/init-cmd";
import { intro, outro, confirm } from '../lib/clack/prompts';
import { addItem, CURRENT_DATABASE_VERSION, rebuildTree, saveTree, SortNode, traverseTreeAsync } from "merkle-tree";
import { IDatabaseMetadata, loadMerkleTree, acquireWriteLock, releaseWriteLock, createReadme } from "api";
import { buildDatabaseMerkleTree, deleteDatabaseMerkleTree, saveDatabaseMerkleTree } from "bdb";
import { pathJoin, StoragePrefixWrapper } from "storage";
import { computeHash } from "api";
import { loadPrivateKey, loadPublicKey } from "storage";
import { createPublicKey } from "node:crypto";
import * as fs from "fs/promises";
import { pathExists } from "node-utils";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
    yes?: boolean;
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(context: ICommandContext, options: IUpgradeCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    
    intro(pc.blue(`Upgrading media file database...`));
    
    const { assetStorage, metadataStorage, databaseDir } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);

    let merkleTree = await retry(() => loadMerkleTree(metadataStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    const currentVersion = merkleTree.version;

    log.info(`✓ Found database version ${currentVersion}`);

    if (currentVersion === CURRENT_DATABASE_VERSION) {
        log.info(pc.green(`✓ Database is already at the latest version (${CURRENT_DATABASE_VERSION})`));
        await exit(0);
    } 
    else if (currentVersion >= CURRENT_DATABASE_VERSION) {
        outro(pc.red(`✗ Database version ${currentVersion} is newer than the current supported version ${CURRENT_DATABASE_VERSION}.\n  Please update your Photosphere CLI tool.`));
        await exit(1);
        return;
    }

    log.warn(pc.yellow(`⚠️  IMPORTANT: Database upgrade will modify your database files.`));
    log.warn(pc.yellow(`    It is strongly recommended to backup your database before proceeding.`));
    log.warn(pc.yellow(`    You can backup your database by copying the entire directory:`));
    
    // Provide platform-specific backup commands
    if (process.platform === 'win32') {
        log.warn(pc.yellow(`    xcopy "${databaseDir}" "${databaseDir}-backup" /E /I`));
    } 
    else {
        log.warn(pc.yellow(`    cp -r "${databaseDir}" "${databaseDir}-backup"`));
    }
    console.log("");
    
    let shouldProceed: boolean;
    
    if (options.yes) {
        // Non-interactive mode: proceed automatically
        log.info(pc.blue(`✓ Non-interactive mode: proceeding with database upgrade`));
        shouldProceed = true;
    } else {
        // Interactive mode: ask for confirmation
        const confirmResult = await confirm({
            message: `Do you want to proceed with upgrading from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}?`,
            initialValue: false,
        });
        shouldProceed = confirmResult === true;
    }
    
    if (!shouldProceed) {
        outro(pc.gray("Database upgrade cancelled."));
        await exit(0);
        return;
    }
    
    log.info(`Upgrading database from version ${currentVersion} to version ${CURRENT_DATABASE_VERSION}...`);

    // Acquire write lock before making changes
    if (!await acquireWriteLock(assetStorage, sessionId)) {
        throw new Error(`Failed to acquire write lock for database upgrade.`);
    }

    try {
        // Fill in missing lastModified from file info using async binary tree traversal.
        await traverseTreeAsync<SortNode>(merkleTree.sort, async (node) => {
            if (node.name) {
                if (!node.lastModified) {
                    const fileInfo = await assetStorage.info(node.name);
                    if (fileInfo) {
                        // Fill in missing lastModified from file info
                        node.lastModified = fileInfo.lastModified;
                    }
                }
            }
            return true; // Continue traversal
        });

        if (await assetStorage.dirExists("assets")) {

            log.info("Moving files from 'assets' directory to 'asset' directory...");

            // 
            // Move files and add them to the merkle tree.
            //
            let next: string | undefined = undefined;
            let filesMoved = 0;
            
            do {
                const assetsFiles = await assetStorage.listFiles("assets", 1000, next);
                
                for (const fileName of assetsFiles.names) {
                    const sourceFile = pathJoin("assets", fileName);
                    const destFile = pathJoin("asset", fileName);
                    
                    // Get file info and compute hash of source file
                    const fileInfo = await assetStorage.info(sourceFile);
                    if (fileInfo) {
                        const sourceHash = await computeHash(assetStorage.readStream(sourceFile));
                        
                        // Copy file from assets/ to asset/
                        const readStream = assetStorage.readStream(sourceFile);
                        await assetStorage.writeStream(destFile, fileInfo.contentType, readStream);
                        
                        // Verify the copied file has the same hash
                        const destHash = await computeHash(assetStorage.readStream(destFile));
                        
                        if (sourceHash.toString('hex') !== destHash.toString('hex')) {
                            throw new Error(`Hash mismatch during file move from ${sourceFile} to ${destFile}: source=${sourceHash.toString('hex')}, dest=${destHash.toString('hex')}`);
                        }

                        const destFileInfo = await assetStorage.info(destFile);
                        if (!destFileInfo) {
                            throw new Error(`Failed to get info for file ${destFile}`);
                        }

                        // Only delete the source file after successful verification
                        await assetStorage.deleteFile(sourceFile);

                        merkleTree = addItem<IDatabaseMetadata>(merkleTree, {
                            name: destFile,
                            hash: destHash,
                            length: destFileInfo.length,
                            lastModified: destFileInfo.lastModified,
                        });
                        filesMoved++;
                    }
                }
                
                next = assetsFiles.next;
            } while (next);
            
            log.info(`✓ Moved ${filesMoved} files from 'assets' to 'asset' directory`);
        }

        // Create README.md if it doesn't exist
        const existingReadme = await retry(() => assetStorage.info('README.md'));
        if (!existingReadme) {
            merkleTree = await createReadme(assetStorage, merkleTree);
        }

        // Check if database is encrypted and ensure public key is in .db directory
        // First check if we have a key (which indicates the database is encrypted)
        const resolvedKeyPath = await resolveKeyPath(options.key);
        if (resolvedKeyPath) {
            // Database is encrypted - check if public key marker exists in .db directory
            if (!await metadataStorage.fileExists('.db/encryption.pub')) {
                // Generate public key from private key and save it
                try {
                    let publicKeyPem: string | undefined;
                    const publicKeyPath = `${resolvedKeyPath}.pub`;
                    if (await pathExists(publicKeyPath)) {
                        publicKeyPem = await fs.readFile(publicKeyPath, 'utf8');
                    } else {
                        // Extract public key from private key
                        const privateKey = await loadPrivateKey(resolvedKeyPath);
                        if (privateKey) {
                            const publicKey = createPublicKey(privateKey);
                            publicKeyPem = publicKey.export({
                                type: 'spki',
                                format: 'pem'
                            }) as string;
                        }
                    }
                    
                    if (publicKeyPem) {
                        // Write public key to .db/encryption.pub in metadata storage
                        await metadataStorage.write('.db/encryption.pub', 'text/plain', Buffer.from(publicKeyPem, 'utf8'));
                        log.info(pc.green(`✓ Copied public key to database directory`));
                    }
                } catch (error) {
                    log.error(pc.red(`Warning: Could not copy public key to database directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
                }
            }
        }

        // Rebuild the merkle tree in sorted order with no metadata/
        merkleTree = rebuildTree<IDatabaseMetadata>(merkleTree, ["metadata/", "assets/"]);

        // Count files in the asset directory to get the actual number of imported files
        let filesImported = 0;
        let next: string | undefined = undefined;

        do {
            const assetFiles = await assetStorage.listFiles("asset", 1000, next);
            filesImported += assetFiles.names.length;
            next = assetFiles.next;
        } while (next);

        if (!merkleTree.databaseMetadata) {
            merkleTree.databaseMetadata = { filesImported };
        }
        else {
            merkleTree.databaseMetadata.filesImported = filesImported;
        }                

        // Save the rebuilt tree.
        await retry(() => saveTree(".db/tree.dat", merkleTree!, metadataStorage));

        const bsonDatabaseStorage = new StoragePrefixWrapper(assetStorage, "metadata");

        log.info(pc.blue(`Rebuilding BSON database merkle tree.`));
            
        const bsonDatabaseTree = await buildDatabaseMerkleTree(
            bsonDatabaseStorage,
            uuidGenerator,
            "", // The storage wraps the metadata directory already.
            undefined,
            undefined,
            true
        );
        if (!bsonDatabaseTree.sort) {
            await deleteDatabaseMerkleTree(bsonDatabaseStorage);
        }
        else {
            await saveDatabaseMerkleTree(bsonDatabaseStorage, bsonDatabaseTree);
        }
        log.info(pc.green(`✓ BSON database merkle tree built successfully`));

        log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
    }
    finally {
        await releaseWriteLock(assetStorage);
    }

    await exit(0);
}