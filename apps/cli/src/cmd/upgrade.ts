import { log, retry } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { IBaseCommandOptions, ICommandContext, resolveKeyPems, resolveKeyPemsWithPrompt, selectEncryptionKey, configureS3IfNeeded } from "../lib/init-cmd";
import { createStorageForPath } from "../lib/storage-helper";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { ensureMediaProcessingTools } from "../lib/ensure-tools";
import { intro, confirm, outro } from "../lib/clack/prompts";
import { loadEncryptionKeysFromPem } from "storage";
import { addItem, CURRENT_DATABASE_VERSION, loadTree, rebuildTree, saveTree, SortNode, traverseTreeAsync } from "merkle-tree";
import { IDatabaseMetadata, acquireWriteLock, releaseWriteLock, createReadme, ensureSortIndex, loadDatabaseConfig, saveDatabaseConfig } from "api";
import { BsonDatabase, buildDatabaseMerkleTree, deleteDatabaseMerkleTree, saveDatabaseMerkleTree } from "bdb";
import type { IAsset } from "api";
import type { IStorage } from "storage";
import { pathJoin, walkDirectory } from "storage";
import { computeHash } from "api";

export interface IUpgradeCommandOptions extends IBaseCommandOptions {
    yes?: boolean;
}

//
// First DB version that stores .db/ files encrypted when the database is encrypted.
// Re-encrypt .db/ only when upgrading from before this version.
//
const FIRST_VERSION_WITH_ENCRYPTED_DOT_DB = 6;

//
// Command that upgrades a Photosphere media file database to the latest format.
//
export async function upgradeCommand(context: ICommandContext, options: IUpgradeCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    
    intro(pc.blue(`Upgrading media file database...`));

    const nonInteractive = options.yes ?? false;
    await ensureMediaProcessingTools(nonInteractive);

    let databaseDir: string;
    if (options.db !== undefined) {
        databaseDir = options.db;
    }
    else {
        databaseDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    const metaPath = pathJoin(databaseDir, ".db");
    if (databaseDir.startsWith("s3:") || metaPath.startsWith("s3:")) {
        await configureS3IfNeeded(nonInteractive);
    }

    let keyPems = await resolveKeyPemsWithPrompt(options.key, nonInteractive, false);
    if (options.key && keyPems.length === 0) {
        outro(pc.red(`✗ Encryption key "${options.key}" not found.\n  Use "psi secrets list" to see available keys.`));
        await exit(1);
        return;
    }
    let { options: storageOptions } = await loadEncryptionKeysFromPem(keyPems);
    let { storage: assetStorage, rawStorage } = await createStorageForPath(databaseDir, storageOptions);

    const hasFilesDat = await assetStorage.fileExists(".db/files.dat");
    const hasTreeDat = await assetStorage.fileExists(".db/tree.dat");
    if (!hasFilesDat && !hasTreeDat) {
        outro(pc.red(`✗ No database found at: ${pc.cyan(databaseDir)}\n  The database directory must contain a ".db" folder with files.dat or tree.dat.\n\nTo create a new database at this directory, use:\n  ${pc.cyan(`psi init --db ${databaseDir}`)}`));
        await exit(1);
    }

    if (await assetStorage.fileExists(".db/encryption.pub")) {
        if (keyPems.length === 0) {
            if (nonInteractive) {
                outro(pc.red(`✗ This database is encrypted and requires a private key to access.\n  Please provide the private key using the --key option.`));
                await exit(1);
            }
            log.info(pc.yellow("This database is encrypted and requires a private key to access."));
            const selectedKey = await selectEncryptionKey("Select the encryption key for this database:");
            options.key = selectedKey;
            keyPems = await resolveKeyPems(options.key);
            const { options: newStorageOptions } = await loadEncryptionKeysFromPem(keyPems);
            storageOptions = newStorageOptions;
            const { storage: newAssetStorage } = await createStorageForPath(databaseDir, storageOptions);
            assetStorage = newAssetStorage;
        }
    }

    // Load from .db/files.dat (v6) or .db/tree.dat (legacy). Upgrade will write .db/files.dat and remove .db/tree.dat.
    let merkleTree = await retry(() => loadTree<IDatabaseMetadata>(".db/files.dat", assetStorage))
        ?? await retry(() => loadTree<IDatabaseMetadata>(".db/tree.dat", assetStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree (no .db/files.dat or .db/tree.dat found)`);
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
    log.info("");
    
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
        outro("Database upgrade cancelled.");
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
                        const sourceHash = await computeHash(await assetStorage.readStream(sourceFile));

                        // Copy file from assets/ to asset/
                        const readStream = await assetStorage.readStream(sourceFile);
                        await assetStorage.writeStream(destFile, fileInfo.contentType, readStream);
                        
                        // Verify the copied file has the same hash
                        const destHash = await computeHash(await assetStorage.readStream(destFile));
                        
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
            merkleTree = await createReadme(rawStorage, merkleTree);
        }

        // Check if database is encrypted and ensure public key is in .db directory
        if (keyPems.length > 0) {
            // Database is encrypted - check if public key marker exists in .db directory
            if (!await assetStorage.fileExists('.db/encryption.pub')) {
                // Write public key PEM from key pair
                try {
                    const publicKeyPem = keyPems[0].publicKeyPem;
                    await rawStorage.write('.db/encryption.pub', 'text/plain', Buffer.from(publicKeyPem, 'utf8'));
                    log.info(pc.green(`✓ Wrote public key to database directory`));
                } catch (error) {
                    log.error(pc.red(`Warning: Could not write public key to database directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
                }
            }

            //
            // When upgrading from a version before 6 to 6+, encrypt existing .db/ files that were
            // previously stored unencrypted. From v6 onward these files are already written encrypted.
            //
            if (currentVersion < FIRST_VERSION_WITH_ENCRYPTED_DOT_DB) {
                for await (const { fileName: filePath } of walkDirectory(assetStorage, ".db", [])) {
                    const data = await assetStorage.read(filePath);
                    if (data) {
                        const info = await assetStorage.info(filePath);
                        await assetStorage.write(filePath, info?.contentType, data);
                    }
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

        // Save the rebuilt tree to .db/files.dat (v6 path; encrypted when DB is encrypted).
        await retry(() => saveTree(".db/files.dat", merkleTree!, assetStorage));
        if (await assetStorage.fileExists(".db/tree.dat")) {
            await assetStorage.deleteFile(".db/tree.dat");
        }

        // Migrate BSON from metadata/ to .db/bson/ when metadata/ exists (copy only; rest of upgrade still uses metadata/)
        if (await assetStorage.dirExists("metadata")) {
            log.info(pc.blue(`Migrating BSON from metadata/ to .db/bson/.`));
            await migrateBsonV5ToV6(assetStorage, "metadata", ".db/bson");
            log.info(pc.green(`✓ BSON migrated to .db/bson/`));
        }

        log.info(pc.blue(`Rebuilding BSON database merkle tree.`));

        const bsonDatabaseTree = await buildDatabaseMerkleTree(
            assetStorage,
            ".db/bson",
            uuidGenerator,
            undefined,
            undefined,
            true
        );
        if (!bsonDatabaseTree.sort) {
            await deleteDatabaseMerkleTree(assetStorage, ".db/bson");
        }
        else {
            await saveDatabaseMerkleTree(assetStorage, ".db/bson", bsonDatabaseTree);
        }
        log.info(pc.green(`✓ BSON database merkle tree built successfully`));

        // Delete and rebuild sort indexes under .db/bson so they use v6 format (type code + checksum).
        log.info(pc.blue(`Rebuilding sort indexes.`));
        const bsonDb = new BsonDatabase(assetStorage, ".db/bson", uuidGenerator, timestampProvider);
        const v6MetadataCollection = bsonDb.collection<IAsset>("metadata");
        const existingIndexes = await v6MetadataCollection.sortIndexes();
        for (const index of existingIndexes) {
            await v6MetadataCollection.sortIndex(index.fieldName, index.direction).drop();
        }
        await ensureSortIndex(v6MetadataCollection);
        log.info(pc.green(`✓ Sort indexes rebuilt successfully`));

        // Remove the old metadata/ directory now that everything is in .db/bson/
        if (await assetStorage.dirExists("metadata")) {
            await assetStorage.deleteDir("metadata");
            log.info(pc.green(`✓ Removed metadata/ directory`));
        }

        // Ensure .db/config.json exists (create empty if not present)
        const existingConfig = await loadDatabaseConfig(rawStorage);
        if (existingConfig === null) {
            await saveDatabaseConfig(rawStorage, {});
            log.info(pc.green(`✓ Created .db/config.json`));
        }

        log.info(pc.green(`✓ Database upgraded successfully to version ${CURRENT_DATABASE_VERSION}`));
        log.info('');
        log.info(pc.bold('Next steps:'));
        log.info(`    # View database summary and tree hash`);
        log.info(`    psi summary --db ${databaseDir}`);
        log.info('');
        log.info(`    # Verify the integrity of the upgraded database`);
        log.info(`    psi verify --db ${databaseDir}`);
    }
    finally {
        await releaseWriteLock(assetStorage);
    }

    await exit(0);
}

//
// Copies a file within the same storage.
//
async function copyStorageFile(storage: IStorage, src: string, dest: string): Promise<void> {
    const data = await storage.read(src);
    if (data) {
        await storage.write(dest, undefined, data);
    }
}

//
// Copies a directory recursively (files only; subdirs are traversed).
//
async function copyStorageDirRecursive(storage: IStorage, srcPrefix: string, destPrefix: string): Promise<void> {
    let next: string | undefined = undefined;
    do {
        const fileResult = await storage.listFiles(srcPrefix, 1000, next);
        for (const name of fileResult.names) {
            const src = pathJoin(srcPrefix, name);
            const dest = pathJoin(destPrefix, name);
            await copyStorageFile(storage, src, dest);
        }
        next = fileResult.next;
    } while (next);

    next = undefined;
    do {
        const dirResult = await storage.listDirs(srcPrefix, 1000, next);
        for (const name of dirResult.names) {
            await copyStorageDirRecursive(storage, pathJoin(srcPrefix, name), pathJoin(destPrefix, name));
        }
        next = dirResult.next;
    } while (next);
}

//
// Copies BSON from srcPrefix (v5 layout: <name>/ collection dirs, sort_indexes/) to destPrefix
// with v6 layout (collections/, shards/, indexes/). Does not copy sort_indexes (rebuilt later).
// Does not delete srcPrefix so callers that still use the source root keep working.
//
async function migrateBsonV5ToV6(
    storage: IStorage,
    srcPrefix: string,
    destPrefix: string
): Promise<void> {
    if (await storage.fileExists(pathJoin(srcPrefix, "db.dat"))) {
        await copyStorageFile(
            storage,
            pathJoin(srcPrefix, "db.dat"),
            pathJoin(destPrefix, "db.dat")
        );
    }

    let next: string | undefined = undefined;
    const v5CollectionDirs: string[] = [];
    do {
        const result = await storage.listDirs(srcPrefix, 1000, next);
        for (const name of result.names) {
            if (name !== "sort_indexes" && name !== "collections" && name !== "indexes") {
                v5CollectionDirs.push(name);
            }
        }
        next = result.next;
    } while (next);

    for (const collectionName of v5CollectionDirs) {
        const srcDir = pathJoin(srcPrefix, collectionName);
        let fileNext: string | undefined = undefined;
        do {
            const fileResult = await storage.listFiles(srcDir, 1000, fileNext);
            for (const fileName of fileResult.names) {
                const srcPath = pathJoin(srcDir, fileName);
                if (fileName === "collection.dat") {
                    await copyStorageFile(
                        storage,
                        srcPath,
                        pathJoin(destPrefix, "collections", collectionName, "collection.dat")
                    );
                }
                else {
                    await copyStorageFile(
                        storage,
                        srcPath,
                        pathJoin(destPrefix, "collections", collectionName, "shards", fileName)
                    );
                }
            }
            fileNext = fileResult.next;
        } while (fileNext);
    }
}