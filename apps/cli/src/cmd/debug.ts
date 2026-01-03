import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { log } from "utils";
import { visualizeTree, iterateLeaves, MerkleNode, getItemInfo } from "merkle-tree";
import { 
    loadDatabaseMerkleTree,
    loadCollectionMerkleTree,
    loadShardMerkleTree,
    listShards,
    hashRecord
} from "bdb";
import { StoragePrefixWrapper } from "storage";
import { loadMerkleTree, getDatabaseSummary, removeAsset } from "api";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { formatBytes } from '../lib/format';
import * as fs from 'fs/promises';
import * as path from 'path';

export interface IDebugMerkleTreeCommandOptions extends IBaseCommandOptions {
    records?: boolean;
    all?: boolean;
}

//
// Helper function to truncate long string values and limit object fields for display
//
function truncateLongStrings(obj: any, maxLength: number = 100, maxFields: number = 5, showAllFields: boolean = false): any {
    if (typeof obj === 'string') {
        if (obj.length > maxLength) {
            return obj.substring(0, maxLength) + '...';
        }
        return obj;
    }
    
    if (Array.isArray(obj)) {
        return obj.map(item => truncateLongStrings(item, maxLength, maxFields, showAllFields));
    }
    
    if (obj !== null && typeof obj === 'object') {
        const entries = Object.entries(obj);
        const result: any = {};
        
        // If showAllFields is true, use all entries; otherwise limit to maxFields
        const limitedEntries = showAllFields ? entries : entries.slice(0, maxFields);
        
        for (const [key, value] of limitedEntries) {
            result[key] = truncateLongStrings(value, maxLength, maxFields, showAllFields);
        }
        
        // If there are more fields than the limit and we're not showing all, add an indicator
        if (!showAllFields && entries.length > maxFields) {
            result['...'] = `${entries.length - maxFields} more fields`;
        }
        
        return result;
    }
    
    return obj;
}

//
// Command to visualize all merkle trees in a media file database.
//
export async function debugMerkleTreeCommand(context: ICommandContext, options: IDebugMerkleTreeCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { assetStorage, metadataStorage, bsonDatabase } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);
    
    log.info('');
    log.info(pc.bold(pc.blue(`🌳 Merkle Trees Visualization`)));
    log.info('');
    
    // Get and display the aggregate root hash
    const summary = await getDatabaseSummary(assetStorage, metadataStorage);
    log.info(pc.cyan('Aggregate Root Hash:'));
    log.info(pc.gray('='.repeat(60)));
    log.info(pc.white(summary.fullHash));
    log.info('');
    
    // Show files merkle tree
    log.info(pc.cyan('Files Merkle Tree (.db/tree.dat):'));
    log.info(pc.gray('='.repeat(60)));
    const filesTree = await loadMerkleTree(metadataStorage);
    if (filesTree) {
        const filesVisualization = visualizeTree(filesTree);
        log.info(filesVisualization);
    } else {
        log.info(pc.yellow('No files merkle tree found.'));
    }
    
    // Show BSON database merkle tree if it exists
    const bsonMetadataStorage = new StoragePrefixWrapper(assetStorage, "metadata");
    const databaseTree = await loadDatabaseMerkleTree(bsonMetadataStorage);
    
    if (databaseTree) {
        log.info('');
        log.info(pc.cyan('BSON Database Merkle Tree (metadata/db.dat):'));
        log.info(pc.gray('='.repeat(60)));
        const databaseVisualization = visualizeTree(databaseTree);
        log.info(databaseVisualization);
        
        // Show all collection trees
        log.info('');
        log.info(pc.cyan('Collection Merkle Trees:'));
        log.info(pc.gray('='.repeat(60)));
        
        const collections = await bsonDatabase.collections();
        
        if (collections.length === 0) {
            log.info(pc.yellow('No collections found in database.'));
        } else {
            for (const collectionName of collections) {
                const collectionTree = await loadCollectionMerkleTree(bsonMetadataStorage, collectionName);
                if (collectionTree) {
                    log.info('');
                    log.info(pc.cyan(`Collection: ${collectionName}`));
                    log.info(pc.gray('-'.repeat(60)));
                    const collectionVisualization = visualizeTree(collectionTree);
                    log.info(collectionVisualization);
                } else {
                    log.info('');
                    log.info(pc.cyan(`Collection: ${collectionName}`));
                    log.info(pc.yellow('  (no merkle tree found)'));
                }
                
                const collection = bsonDatabase.collection(collectionName);

                // Show all shard trees for this collection
                const shardIds = await listShards(bsonMetadataStorage, collectionName);
                for (const shardId of shardIds) {
                    const shardTree = await loadShardMerkleTree(bsonMetadataStorage, collectionName, shardId);
                    if (shardTree) {
                        log.info('');
                        log.info(pc.cyan(`  Shard: ${shardId}`));
                        log.info(pc.gray('  ' + '-'.repeat(58)));
                        const shardVisualization = visualizeTree(shardTree);
                        // Indent shard visualization
                        const indentedVisualization = shardVisualization.split('\n').map(line => `  ${line}`).join('\n');
                        log.info(indentedVisualization);
                    }
                    else {
                        log.info('');
                        log.info(pc.yellow(`    No shard tree found for shard ${shardId}`));
                    }
                    
                    // Show records if --records flag is set (even if no shard tree)
                    if (options.records) {
                        const shard = await collection.loadShard(shardId);
                        if (shard.records.size > 0) {
                            log.info('');
                            log.info(pc.cyan(`    Records in shard ${shardId}:`));
                            for (const [recordId, record] of shard.records) {
                                // Compute hash for the record
                                const hashedItem = hashRecord(record);
                                const hashHex = hashedItem.hash.toString('hex');
                                
                                log.info(pc.white(`      ${recordId}:`));
                                log.info(pc.gray(`        Hash: ${hashHex}`));
                                // Truncate long strings unless --all is used
                                const recordToDisplay = options.all ? record : truncateLongStrings(record, 100, 5, false);
                                const recordJson = JSON.stringify(recordToDisplay, null, 2);
                                // Indent each line of the JSON
                                const indentedJson = recordJson.split('\n').map(line => `        ${line}`).join('\n');
                                log.info(pc.gray(indentedJson));
                            }
                        } else {
                            log.info('');
                            log.info(pc.yellow(`    No records in shard ${shardId}`));
                        }
                    }
                }
            }
        }
    } else {
        log.info('');
        log.info(pc.yellow('No BSON database merkle tree found (database may not have BSON collections yet).'));
    }
    
    log.info('');
    
    await exit(0);
}

export interface IDebugFindCollisionsCommandOptions extends IBaseCommandOptions {
    //
    // Source database directory.
    //
    db?: string;
    
    //
    // Output JSON file path.
    //
    output?: string;
}

export interface IDebugFindDuplicatesCommandOptions extends IBaseCommandOptions {
    //
    // Input JSON file path from find-collisions.
    //
    input?: string;
    
    //
    // Output JSON file path.
    //
    output?: string;
    
    //
    // Source database directory (needed to read files).
    //
    db?: string;
}

export interface IDebugRemoveDuplicatesCommandOptions extends IBaseCommandOptions {
    //
    // Input JSON file path from find-duplicates.
    //
    input?: string;
    
    //
    // Source database directory.
    //
    db?: string;
}

interface CollisionFile {
    assetId: string;
    size: number;
    time: string;
}

interface CollisionsData {
    [hash: string]: CollisionFile[];
}

interface ContentGroup {
    assetIds: string[];
}

interface DuplicatesData {
    [hash: string]: ContentGroup[];
}

//
// Command that finds hash collisions (same hash, different asset IDs).
//
export async function debugFindCollisionsCommand(context: ICommandContext, options: IDebugFindCollisionsCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    let dbDir = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    // Load the database
    const { metadataStorage, databaseDir: dbDirResolved } = await loadDatabase(dbDir, options, false, uuidGenerator, timestampProvider, sessionId);

    log.info('');
    log.info(`Finding hash collisions in database:`);
    log.info(`  Database: ${pc.cyan(dbDirResolved)}`);
    log.info('');

    // Load merkle tree from the database
    writeProgress(`Loading merkle tree...`);
    const merkleTree = await loadMerkleTree(metadataStorage);
    if (!merkleTree || !merkleTree.merkle) {
        clearProgressMessage();
        log.info(pc.red(`Error: Failed to load database merkle tree`));
        await exit(1);
        return;
    }

    // Collect all leaf nodes from asset subdirectory and group by hash
    writeProgress(`Walking merkle tree to find collisions...`);
    const hashMap = new Map<string, string[]>(); // hash -> array of asset IDs

    const merkleRoot = merkleTree.merkle;
    for (const leaf of iterateLeaves<MerkleNode>(merkleRoot)) {
        if (!leaf.name || !leaf.hash) {
            continue;
        }

        // Only consider files in the asset subdirectory
        if (!leaf.name.startsWith('asset/')) {
            continue;
        }

        // Extract asset ID from path (asset/{assetId})
        const assetId = leaf.name.substring(6);

        const hashHex = leaf.hash.toString('hex');
        const assetIds = hashMap.get(hashHex) || [];
        assetIds.push(assetId);
        hashMap.set(hashHex, assetIds);
    }

    clearProgressMessage();

    // Find collisions (hashes with more than one asset ID)
    const collisions = Array.from(hashMap.entries())
        .filter(([_, assetIds]) => assetIds.length > 1)
        .sort((a, b) => b[1].length - a[1].length);

    // Build collisions data structure
    const collisionsData: CollisionsData = {};
    for (const [hash, assetIds] of collisions) {
        const files: CollisionFile[] = [];
        for (const assetId of assetIds) {
            const filePath = `asset/${assetId}`;
            const fileInfo = getItemInfo(merkleTree, filePath);
            if (fileInfo) {
                files.push({
                    assetId,
                    size: fileInfo.length,
                    time: fileInfo.lastModified.toISOString()
                });
            }
            else {
                files.push({
                    assetId,
                    size: 0,
                    time: ''
                });
            }
        }
        collisionsData[hash] = files;
    }

    // Write JSON file (default to collisions.json in database directory if relative path)
    const outputPath = options.output 
        ? (path.isAbsolute(options.output) ? options.output : path.join(dbDirResolved, options.output))
        : path.join(dbDirResolved, 'collisions.json');
    await fs.writeFile(outputPath, JSON.stringify(collisionsData, null, 2), 'utf8');

    log.info('');
    log.info(pc.bold(pc.blue(`📊 Summary`)));
    log.info(`Total collisions: ${pc.cyan(collisions.length.toString())}`);
    log.info(`Total asset IDs in collisions: ${pc.cyan(collisions.reduce((sum, [_, assetIds]) => sum + assetIds.length, 0).toString())}`);
    log.info(`Output file: ${pc.cyan(outputPath)}`);
    log.info('');

    await exit(0);
}

//
// Command that finds duplicate assets by comparing file content.
//
export async function debugFindDuplicatesCommand(context: ICommandContext, options: IDebugFindDuplicatesCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    // Load the database first to get the directory for default paths
    let dbDir = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    const { databaseDir: dbDirResolved } = await loadDatabase(dbDir, options, false, uuidGenerator, timestampProvider, sessionId);

    // Get input file path (default to collisions.json in database directory)
    const inputPath = options.input
        ? (path.isAbsolute(options.input) ? options.input : path.join(dbDirResolved, options.input))
        : path.join(dbDirResolved, 'collisions.json');

    let collisionsData: CollisionsData;
    try {
        const inputContent = await fs.readFile(inputPath, 'utf8');
        collisionsData = JSON.parse(inputContent) as CollisionsData;
    }
    catch (error: unknown) {
        log.info(pc.red(`Error: Failed to read input file ${inputPath}: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
        return;
    }

    log.info('');
    log.info(`Finding duplicate assets by comparing file sizes:`);
    log.info(`  Input file: ${pc.cyan(inputPath)}`);
    log.info(`  Database: ${pc.cyan(dbDirResolved)}`);
    log.info('');

    // Group asset IDs by file size (files with same hash and same size are duplicates)
    const duplicatesData: DuplicatesData = {};
    const hashes = Object.keys(collisionsData);
    
    writeProgress(`Grouping files by size...`);
    for (const hash of hashes) {
        const files = collisionsData[hash];
        const sizeGroups = new Map<number, string[]>(); // size -> asset IDs[]
        
        // Group asset IDs by their file size
        for (const file of files) {
            const size = file.size;
            const groupAssetIds = sizeGroups.get(size) || [];
            groupAssetIds.push(file.assetId);
            sizeGroups.set(size, groupAssetIds);
        }
        
        // Convert to output format (array of content groups)
        const contentGroups: ContentGroup[] = [];
        for (const [size, assetIds] of sizeGroups.entries()) {
            if (assetIds.length > 0) {
                contentGroups.push({ assetIds });
            }
        }
        duplicatesData[hash] = contentGroups;
    }
    clearProgressMessage();

    // Write JSON file (default to duplicates.json in database directory if relative path)
    const outputPath = options.output
        ? (path.isAbsolute(options.output) ? options.output : path.join(dbDirResolved, options.output))
        : path.join(dbDirResolved, 'duplicates.json');
    await fs.writeFile(outputPath, JSON.stringify(duplicatesData, null, 2), 'utf8');

    // Calculate statistics
    const totalCollisions = hashes.length;
    const totalAssetIds = Object.values(collisionsData).reduce((sum, files) => sum + files.length, 0);
    // True duplicates: hashes where all files have the same size (only one content group)
    const trueDuplicates = Object.values(duplicatesData).filter(groups => groups.length === 1).length;
    // Hash collisions: hashes where files have different sizes (multiple content groups)
    const hashCollisions = Object.values(duplicatesData).filter(groups => groups.length > 1).length;

    log.info('');
    log.info(pc.bold(pc.blue(`📊 Summary`)));
    log.info(`Total collisions: ${pc.cyan(totalCollisions.toString())}`);
    log.info(`True duplicates (same content): ${pc.green(trueDuplicates.toString())}`);
    log.info(`Hash collisions (different content): ${hashCollisions > 0 ? pc.red(hashCollisions.toString()) : pc.green('0')}`);
    log.info(`Output file: ${pc.cyan(outputPath)}`);
    log.info('');

    await exit(0);
}

//
// Command that removes duplicate assets based on content comparison results.
//
export async function debugRemoveDuplicatesCommand(context: ICommandContext, options: IDebugRemoveDuplicatesCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    // Load the database first to get the directory for default paths
    let dbDir = options.db;
    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    const { assetStorage, metadataStorage, metadataCollection, databaseDir: dbDirResolved } = await loadDatabase(dbDir, options, false, uuidGenerator, timestampProvider, sessionId);

    // Get input file path (default to duplicates.json in database directory)
    const inputPath = options.input
        ? (path.isAbsolute(options.input) ? options.input : path.join(dbDirResolved, options.input))
        : path.join(dbDirResolved, 'duplicates.json');

    // Load duplicates JSON file
    let duplicatesData: DuplicatesData;
    try {
        const inputContent = await fs.readFile(inputPath, 'utf8');
        duplicatesData = JSON.parse(inputContent) as DuplicatesData;
    }
    catch (error: unknown) {
        log.info(pc.red(`Error: Failed to read input file ${inputPath}: ${error instanceof Error ? error.message : String(error)}`));
        await exit(1);
        return;
    }

    log.info('');
    log.info(`Removing duplicate assets:`);
    log.info(`  Input file: ${pc.cyan(inputPath)}`);
    log.info(`  Database: ${pc.cyan(dbDirResolved)}`);
    log.info('');

    // Collect all asset IDs to remove (keep first in each content group, remove the rest)
    const assetIdsToRemove: string[] = [];
    const hashes = Object.keys(duplicatesData);
    
    writeProgress(`Analyzing duplicates...`);
    for (const hash of hashes) {
        const contentGroups = duplicatesData[hash];
        for (const group of contentGroups) {
            // Keep the first asset ID, remove the rest
            if (group.assetIds.length > 1) {
                assetIdsToRemove.push(...group.assetIds.slice(1));
            }
        }
    }
    clearProgressMessage();

    if (assetIdsToRemove.length === 0) {
        log.info(pc.green(`No duplicate assets to remove.`));
        log.info('');
        await exit(0);
        return;
    }

    log.info(pc.yellow(`Found ${assetIdsToRemove.length} duplicate asset${assetIdsToRemove.length === 1 ? '' : 's'} to remove`));
    log.info('');

    // Remove each duplicate asset
    writeProgress(`Removing duplicate assets...`);
    let removed = 0;
    let errors = 0;
    
    for (let i = 0; i < assetIdsToRemove.length; i++) {
        const assetId = assetIdsToRemove[i];
        try {
            await removeAsset(assetStorage, metadataStorage, sessionId, metadataCollection, assetId, false);
            removed++;
            if ((i + 1) % 10 === 0) {
                writeProgress(`Removing duplicate assets... (${i + 1}/${assetIdsToRemove.length})`);
            }
        }
        catch (error: unknown) {
            errors++;
            log.verbose(`Failed to remove asset ${assetId}: ${error instanceof Error ? error.message : String(error)}`);
        }
    }
    clearProgressMessage();

    log.info('');
    log.info(pc.bold(pc.blue(`📊 Summary`)));
    log.info(`Assets removed: ${pc.green(removed.toString())}`);
    if (errors > 0) {
        log.info(`Errors: ${pc.red(errors.toString())}`);
    }
    log.info('');

    await exit(0);
}





