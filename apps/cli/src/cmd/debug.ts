import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { log } from "utils";
import { visualizeTree } from "merkle-tree";
import { 
    loadDatabaseMerkleTree,
    loadCollectionMerkleTree,
    loadShardMerkleTree,
    listShards,
    hashRecord
} from "bdb";
import { StoragePrefixWrapper, IStorage } from "storage";
import { loadMerkleTree, getDatabaseSummary } from "api";

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
    const { assetStorage, bsonDatabase } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);
    
    log.info('');
    log.info(pc.bold(pc.blue(`🌳 Merkle Trees Visualization`)));
    log.info('');
    
    // Get and display the aggregate root hash
    const summary = await getDatabaseSummary(assetStorage);
    log.info(pc.cyan('Aggregate Root Hash:'));
    log.info(pc.gray('='.repeat(60)));
    log.info(pc.white(summary.fullHash));
    log.info('');
    
    // Show files merkle tree
    log.info(pc.cyan('Files Merkle Tree (.db/tree.dat):'));
    log.info(pc.gray('='.repeat(60)));
    const filesTree = await loadMerkleTree(assetStorage);
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

