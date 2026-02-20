//
// Batch variant of sort-index: defers saves until commitChanges().
// Kept in a separate file so the original sort-index.ts remains unchanged; differences are minimal for easy reintegration.
//

import { BSON } from 'bson';
import type { IInternalRecord, IBsonCollection } from './collection';
import type { IStorage } from 'storage';
import { retry } from 'utils';
import type { IUuidGenerator } from 'utils';
import { save, load, BinarySerializer, BinaryDeserializer } from 'serialization';
import type { IDeserializer, ISerializer } from 'serialization';

export type SortDirection = 'asc' | 'desc';
export type SortDataType = 'date' | 'string' | 'number';

//
// Interface for tree data structure
//
interface ITreeData {
    totalEntries: number;
    totalPages: number;
    rootPageId: string;
    fieldName: string;
    direction: SortDirection;
    type: SortDataType | undefined;
    treeNodes: Map<string, IBTreeNode>;
}

export interface IRangeOptions {
    min?: any;
    max?: any;
    minInclusive?: boolean;
    maxInclusive?: boolean;
}

//
// Split internal nodes when they exceed 1.2x the key size.
//
const splitKeysThreshold = 1.2; 

//
// Split leaf nodes when they exceed 1.5x the page size
//
const leafSplitThreshold = 1.5;

export interface ISortedIndexEntry {
    // The record ID.
    _id: string;

    // The record fields.
    fields: {
        [key: string]: any;
    };

    // The value used for sorting
    value: any;
}

export interface ISortIndexOptions {
    // Interface to the file storage system
    storage: IStorage;

    // The directory where sorted indexes are stored
    baseDirectory: string;

    // The collection name
    collectionName: string;

    // The name of the field to sort by
    fieldName: string;

    // Sort direction: 'asc' or 'desc'
    direction: SortDirection;

    // UUID generator for creating unique identifiers
    uuidGenerator: IUuidGenerator;

    // Number of records per page
    pageSize?: number;
    
    // Maximum number of keys per internal node
    keySize?: number;
    
    // Optional type for value conversion before comparison
    // Supports 'date' for ISO string date parsing, 'string' for string comparison, 'number' for numeric comparison
    // If not set, type will be inferred from the values.
    type?: SortDataType;
    
    // Batch size for saving during build (default: 1000)
    buildBatchSize?: number;
    
    // Progress reporting interval during build (default: 100)
    buildProgressInterval?: number;
}

export interface ISortIndexResult {
    // Records for the requested page
    records: ISortedIndexEntry[];

    // Total number of records in the collection
    totalRecords: number;
    
    // Current page ID
    currentPageId: string;
    
    // Total number of leaf pages (navigable data pages)
    totalPages: number;
    
    // Next page ID or undefined if this is the last page
    nextPageId?: string;
    
    // Previous page ID or undefined if this is the first page
    previousPageId?: string;
}

export interface ISortIndex {
    //
    // Loads the sort index metadata and tree nodes from disk.
    //
    load(): Promise<boolean>;

    //
    // Builds the sort index from the collection.
    // @param progressCallback Optional callback to report progress (called every 1000 records)
    //
    build(collection: IBsonCollection<any>, progressCallback?: (message: string) => void): Promise<void>;

    //
    // Get a page of records from the collection using the sort index.
    //
    getPage(pageId?: string): Promise<ISortIndexResult>;
    
    //
    // Delete the entire index
    //
    delete(): Promise<void>;
    
    //
    // Updates a record in the index without rebuilding the entire index
    // If the indexed field value has changed, the record will be removed and added again
    //
    updateRecord(record: IInternalRecord, oldRecord: IInternalRecord | undefined): Promise<void>;
    
    //
    // Deletes a record from the index without rebuilding the entire index
    // @param recordId The ID of the record to delete
    // @param value The value of the indexed field, used to help locate the record
    //
    deleteRecord(recordId: string, oldRecord: IInternalRecord): Promise<void>;
    
    //
    // Adds a new record to the index without rebuilding the entire index
    //
    addRecord(record: IInternalRecord): Promise<void>;
    
    //
    // Find records by exact value using binary search on the sorted index
    //
    findByValue(value: any): Promise<ISortedIndexEntry[]>;
    
    //
    // Find records by range query using optimized leaf traversal.
    //
    findByRange(options: IRangeOptions): Promise<ISortedIndexEntry[]>;
        
    //
    // Visualizes the B-tree structure for debugging purposes
    // Returns a string representation of the tree
    //
    visualizeTree(): Promise<string>;
    
    //
    // Analyze the tree structure and return statistics about keys per node
    //
    analyzeTreeStructure(): Promise<{
        totalNodes: number;
        leafNodes: number;
        internalNodes: number;
        minKeysPerNode: number;
        maxKeysPerNode: number;
        avgKeysPerNode: number;
        nodeKeyDistribution: { nodeId: string; keyCount: number; isLeaf: boolean }[];
        leafStats: {
            minRecordsPerLeaf: number;
            maxRecordsPerLeaf: number;
            avgRecordsPerLeaf: number;
        };
        internalStats: {
            minKeysPerInternal: number;
            maxKeysPerInternal: number;
            avgKeysPerInternal: number;
        };
    }>;
}

// B-tree node interface
interface IBTreeNode {
    keys: any[];  // Values that divide ranges
    children: string[];  // For internal nodes, pageIds of children (empty array means this is a leaf node)
    nextLeaf?: string;  // For leaf nodes, pageId of next leaf for sequential scans
    previousLeaf?: string;  // For leaf nodes, pageId of previous leaf for reverse traversal
    parentId?: string;  // Reference to parent node
    // A node is a leaf if children.length === 0, and NOT a leaf if children.length > 0
}

// Build checkpoint for incremental builds
interface IBuildCheckpoint {
    completedShards: number[];  // Shard IDs that have been fully processed
    currentShard: number | null;  // Current shard being processed (if build was interrupted)
    currentShardRecordIndex: number;  // Record index within current shard to resume from
    totalRecordsProcessed: number;  // Total records processed so far
    lastUpdated: number;  // Timestamp when checkpoint was created/updated
}

//
// Sort index that defers all writes until commitChanges(). Extends ISortIndex with commitChanges().
//
export interface IBatchSortIndex extends ISortIndex {
    //
    // Writes all deferred leaf/tree updates and deletes to storage, then clears deferred state.
    //
    commitChanges(): Promise<void>;
}

//
// Batch-only sort index: add/update/delete only update in-memory state; call commitChanges() to persist.
//
export class BatchSortIndex implements IBatchSortIndex {
    private storage: IStorage;
    private indexDirectory: string;
    private fieldName: string;
    private direction: SortDirection;
    private pageSize: number;
    private keySize: number;
    private totalEntries: number = 0;
    private totalPages: number = 0; // Tracks only leaf nodes (user-facing pages)
    private loaded: boolean = false;
    private rootPageId: string | undefined;
    private type?: SortDataType; // Optional type for value conversion
    
    // Path to the single file that contains all tree nodes and metadata
    private treeFilePath: string;
    
    // Path to the checkpoint file for incremental builds
    private checkpointFilePath: string;
    
    // Map of all tree nodes
    private treeNodes: Map<string, IBTreeNode> = new Map();
    
    // UUID generator for creating unique identifiers
    private readonly uuidGenerator: IUuidGenerator;
    
    // Build configuration
    private readonly buildBatchSize: number;
    private readonly buildProgressInterval: number;

    private leafCache: Map<string, ISortedIndexEntry[]> = new Map();
    private dirtyLeaves: Set<string> = new Set();
    private treeChanged = false;
    private deletedLeaves: Set<string> = new Set();

    //
    // Creates a batch sort index. Same options as SortIndex; all writes are deferred until commitChanges().
    //
    constructor(options: ISortIndexOptions) {
        this.storage = options.storage;
        this.indexDirectory = `${options.baseDirectory}/sort_indexes/${options.collectionName}/${options.fieldName}_${options.direction}`;
        this.fieldName = options.fieldName;
        this.direction = options.direction;
        this.pageSize = options.pageSize || 1000;
        this.keySize = options.keySize || 100;
        this.type = options.type;
        this.treeFilePath = `${this.indexDirectory}/tree.dat`;
        this.checkpointFilePath = `${this.indexDirectory}/build.checkpoint`;
        this.uuidGenerator = options.uuidGenerator;
        this.buildBatchSize = options.buildBatchSize || 10000;
        this.buildProgressInterval = options.buildProgressInterval || 100;
    }

    //
    // Deserializer function for tree data
    //
    private deserializeTree(deserializer: IDeserializer): ITreeData {
        // Read metadata directly as binary data
        const totalEntries = deserializer.readUInt32();
        const totalPages = deserializer.readUInt32();
        
        // Read rootPageId with length prefix
        const rootPageIdBuffer = deserializer.readBuffer();
        const rootPageId = rootPageIdBuffer.toString('utf8');
        
        // Read fieldName with length prefix
        const fieldNameBuffer = deserializer.readBuffer();
        const fieldName = fieldNameBuffer.toString('utf8');
        
        // Read direction with length prefix
        const directionBuffer = deserializer.readBuffer();
        const direction = directionBuffer.toString('utf8') as SortDirection;
        
        // Read type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
        const typeValue = deserializer.readUInt8();
        let type: SortDataType | undefined;
        if (typeValue === 1) {
            type = 'date';
        } else if (typeValue === 2) {
            type = 'string';
        } else if (typeValue === 3) {
            type = 'number';
        } else {
            type = undefined;
        }
                     
        // Skip what used to be the lastUpdatedAt timestamp (8 bytes LE)
        deserializer.readUInt64();
        
        // Read number of nodes (4 bytes LE)
        const nodeCount = deserializer.readUInt32();
        
        // Read each node
        const treeNodes = new Map<string, IBTreeNode>();
        for (let i = 0; i < nodeCount; i++) {
            // Read pageId with length prefix
            const pageIdBuffer = deserializer.readBuffer();
            const pageId = pageIdBuffer.toString('utf8');
            
            // Deserialize node directly from the deserializer
            const node = this.deserializeNode(deserializer);
            treeNodes.set(pageId, node);
        }

        return {
            totalEntries,
            totalPages,
            rootPageId,
            fieldName,
            direction,
            type,
            treeNodes
        };
    }

    //
    // Loads the sort index metadata and tree nodes from disk.
    // Returns false if the sort index is not built.
    //
    async load(): Promise<boolean> {
        if (this.loaded) {
            return true; // Already loaded
        }
        
        const treeData = await load<ITreeData>(
            this.storage,
            this.treeFilePath,
            {
                2: (deserializer) => this.deserializeTree(deserializer)
            }
        );
        if (!treeData) {
            return false;
        }

        this.totalEntries = treeData.totalEntries;
        this.totalPages = treeData.totalPages;
        this.rootPageId = treeData.rootPageId || this.rootPageId;
        this.treeNodes = treeData.treeNodes;
        
        this.reconstructParentChildRelationships();
        
        this.loaded = true;
        return true;
    }
    
    // Reconstruct parent-child relationships for all nodes
    private reconstructParentChildRelationships(): void {
        if (!this.rootPageId) return;
        
        // Start with the root node, which has no parent
        const rootNode = this.treeNodes.get(this.rootPageId);
        if (!rootNode) {
            return;
        }
        
        // Root node has no parent
        rootNode.parentId = undefined;
        
        // Recursively set parents for all children
        const setParentsForChildren = (nodeId: string): void => {
            const node = this.treeNodes.get(nodeId);
            if (!node || node.children.length === 0) {
                return;
            }
            
            // For each child of this node, set its parent to this node
            for (const childId of node.children) {
                const childNode = this.treeNodes.get(childId);
                if (childNode) {
                    childNode.parentId = nodeId;
                    
                    // If the child is an internal node, process its children
                    if (childNode.children.length > 0) {
                        setParentsForChildren(childId);
                    }
                }
            }
        };
        
        // Start the recursion from the root
        setParentsForChildren(this.rootPageId);
    }

    // Serialize a single node to a buffer
    private serializeNode(node: IBTreeNode, serializer: ISerializer): void {

        serializer.writeUInt32(0); // Each node used to store a buffer prefixed with the length. Write this for backward compatibility.

        // Serialize keys as BSON
        serializer.writeBSON({ keys: node.keys });
        
        // Write children count (4 bytes) and children data
        // Note: A node is a leaf if children.length === 0, no need for separate isLeaf flag
        serializer.writeUInt32(node.children.length);
        
        for (const child of node.children) {
            serializer.writeString(child);
        }
        
        // Write nextLeaf (empty string if undefined)
        serializer.writeString(node.nextLeaf || '');
        
        // Write previousLeaf (empty string if undefined)
        serializer.writeString(node.previousLeaf || '');
               
        // parentId is deliberately not serialized - it will be reconstructed during load
    }
    
    // Deserialize a single node from a deserializer
    private deserializeNode(deserializer: IDeserializer): IBTreeNode {

        deserializer.readUInt32(); // Each node use to be stored a buffer prefixed with the lenght. Need to drop this.

        // Read keys as BSON
        const keysData = deserializer.readBSON<{ keys: any[] }>();
        const keys = keysData.keys || [];
        
        // Read children count and data
        const childrenCount = deserializer.readUInt32();
        const children: string[] = [];
        
        for (let i = 0; i < childrenCount; i++) {
            children.push(deserializer.readString());
        }
        
        // Read nextLeaf (empty string becomes undefined)
        const nextLeaf = deserializer.readString() || undefined;
        
        // Read previousLeaf (empty string becomes undefined)
        const previousLeaf = deserializer.readString() || undefined;
        
        // parentId is not present in the serialized format anymore
        // It will be reconstructed after loading all nodes
        
        return {
            keys,
            children,
            nextLeaf,
            previousLeaf,
            // parentId is initially undefined
            // A node is a leaf if children.length === 0
        };
    }

    //
    // Data structure for tree serialization
    //
    private getTreeData(): ITreeData {
        return {
            totalEntries: this.totalEntries,
            totalPages: this.totalPages,
            rootPageId: this.rootPageId!, // Non-null assertion - checked in saveTree
            fieldName: this.fieldName,
            direction: this.direction,
            type: this.type,
            treeNodes: this.treeNodes
        };
    }

    //
    // Serializer function for tree data (without version, as save() handles that)
    //
    private serializeTree(treeData: ITreeData, serializer: ISerializer): void {
        // Sort entries by pageId for deterministic ordering
        const sortedEntries = Array.from(treeData.treeNodes.entries()).sort(([a], [b]) => a.localeCompare(b));
        
        // Write metadata directly as binary data
        serializer.writeUInt32(treeData.totalEntries);
        serializer.writeUInt32(treeData.totalPages);
        
        // Write rootPageId with length prefix
        const rootPageIdBuffer = Buffer.from(treeData.rootPageId, 'utf8');
        serializer.writeBuffer(rootPageIdBuffer);
        
        // Write fieldName with length prefix
        const fieldNameBuffer = Buffer.from(treeData.fieldName, 'utf8');
        serializer.writeBuffer(fieldNameBuffer);
        
        // Write direction with length prefix
        const directionBuffer = Buffer.from(treeData.direction, 'utf8');
        serializer.writeBuffer(directionBuffer);
        
        // Write type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
        let typeValue = 0;
        if (treeData.type === 'date') {
            typeValue = 1;
        } else if (treeData.type === 'string') {
            typeValue = 2;
        } else if (treeData.type === 'number') {
            typeValue = 3;
        }
        serializer.writeUInt8(typeValue);
               
        // Write lastUpdatedAt timestamp (8 bytes LE) - now set to 0n for compatibility
        serializer.writeUInt64(0n);
        
        // Write number of nodes (4 bytes LE)
        serializer.writeUInt32(treeData.treeNodes.size);
        
        // Write each node
        for (const [pageId, node] of sortedEntries) {
            const pageIdBuffer = Buffer.from(pageId, 'utf8');
            
            // Write pageId with length prefix
            serializer.writeBuffer(pageIdBuffer);
            
            // Serialize node directly to the serializer (no length prefix wrapper needed)
            this.serializeNode(node, serializer);
        }
    }

    // Save checkpoint for incremental builds
    private async saveCheckpoint(checkpoint: IBuildCheckpoint): Promise<void> {
        checkpoint.lastUpdated = Date.now();
        const json = JSON.stringify(checkpoint);
        await this.storage.write(this.checkpointFilePath, 'application/json', Buffer.from(json, 'utf-8'));
    }
    
    // Load checkpoint for incremental builds
    private async loadCheckpoint(): Promise<IBuildCheckpoint | null> {
        const buffer = await this.storage.read(this.checkpointFilePath);
        if (!buffer) {
            return null;
        }
        try {
            const json = buffer.toString('utf-8');
            return JSON.parse(json) as IBuildCheckpoint;
        } catch (error) {
            // Corrupted checkpoint, return null to start fresh
            return null;
        }
    }
    
    // Delete checkpoint file (called when build completes successfully)
    private async deleteCheckpoint(): Promise<void> {
        try {
            await this.storage.deleteFile(this.checkpointFilePath);
        } catch (error) {
            // Ignore errors if file doesn't exist
        }
    }
    
    //
    // Marks the tree as changed (deferred until commitChanges). Does not write to storage.
    //
    saveTree(): void {
        this.treeChanged = true;
    }

    //
    // Writes the current tree and metadata to storage. Used by commitChanges().
    //
    private async writeTreeToStorage(): Promise<void> {
        if (!this.rootPageId) {
            throw new Error('Root page ID is not set. Cannot save tree.');
        }
        await save(
            this.storage,
            this.treeFilePath,
            this.getTreeData(),
            2,
            (treeData, serializer) => this.serializeTree(treeData, serializer)
        );
    }

    //
    // Builds the sort index by directly inserting records from the collection.
    //
    async build(collection: IBsonCollection<any>, progressCallback?: (message: string) => void): Promise<void> {
        // Load checkpoint if it exists (incremental build)
        let checkpoint = await this.loadCheckpoint();
        
        // If no checkpoint and index is already loaded, return early
        if (!checkpoint && this.loaded) {
            return;
        }

        // Initialize or load index
        if (!this.loaded) {
            // Try to load existing index first (in case we're resuming from checkpoint)
            const loaded = await this.load();
            
            if (!loaded) {
                // No existing index - if checkpoint exists, it's stale (e.g., after rebuild)
                // Delete the stale checkpoint and start fresh
                if (checkpoint) {
                    await this.deleteCheckpoint();
                    checkpoint = null;
                }
                
                // Create new index
                // Clear any existing tree nodes to start fresh
                this.treeNodes.clear();
              
                // Create an empty root leaf node to start with (empty children array means it's a leaf)
                const emptyRoot: IBTreeNode = {
                    keys: [],
                    children: [],
                    nextLeaf: undefined,
                    previousLeaf: undefined,
                    parentId: undefined,
                };

                this.rootPageId = this.uuidGenerator.generate(); // Generate a new UUID for the root page ID.
                
                // Store in the tree nodes map
                this.treeNodes.set(this.rootPageId, emptyRoot);
                
                // Create empty leaf records array
                const emptyLeafRecords: ISortedIndexEntry[] = [];
                this.saveLeafRecords(this.rootPageId, emptyLeafRecords);
                
                this.totalEntries = 0;
                this.totalPages = 1; // Start with a single leaf page
            }
            // If loaded successfully, use existing index state
            // Note: this.loaded is set to true by load(), but we continue building if checkpoint exists
        }
        
        // Create initial checkpoint if it doesn't exist
        if (!checkpoint) {
            checkpoint = {
                completedShards: [],
                currentShard: null,
                currentShardRecordIndex: 0,
                totalRecordsProcessed: this.totalEntries,
                lastUpdated: Date.now()
            };
            await this.saveCheckpoint(checkpoint);
        }
        
        // Temporarily set loaded to false to allow building to continue
        // We'll set it back to true at the end (or in finally block if aborted)
        const wasLoaded = this.loaded;
        this.loaded = false;
        
        // Local cache for batched writes - only keeps pages being actively modified
        const leafRecordsCache: Map<string, ISortedIndexEntry[]> = new Map();
        const dirtyLeafNodes: Set<string> = new Set();
        let treeStructureChanged = false;
        let recordsAdded = 0;
        
        // Performance timers and counters
        let timeInTreeTraversal = 0;
        let timeInLoadRecords = 0;
        let timeInBinarySearch = 0;
        let timeInSplice = 0;
        let timeInSplit = 0;
        let timeInSave = 0;
        let timeInFlush = 0;
        
        let countTreeTraversal = 0;
        let countLoadRecords = 0;
        let countBinarySearch = 0;
        let countSplice = 0;
        let countSplit = 0;
        let countSave = 0;
        let countFlush = 0;
       
        // Helper function to flush dirty nodes to disk
        const flushDirtyNodes = async (): Promise<void> => {
            const flushStart = performance.now();
            for (const leafId of dirtyLeafNodes) {
                const leafRecords = leafRecordsCache.get(leafId);
                if (leafRecords) {
                    const saveStart = performance.now();
                    this.saveLeafRecords(leafId, leafRecords);
                    const saveTime = performance.now() - saveStart;
                    timeInSave += saveTime;
                    countSave++;
                    // Remove from cache once written (page is full or being flushed)
                    leafRecordsCache.delete(leafId);
                }
            }
            dirtyLeafNodes.clear();
            
            if (treeStructureChanged) {
                this.saveTree();
                treeStructureChanged = false;
            }
            const flushTime = performance.now() - flushStart;
            timeInFlush += flushTime;
            countFlush++;
        };

        // Helper function to add a record with batching
        const addRecordBatched = async (record: IInternalRecord): Promise<void> => {
            const recordId = record._id;
            const value = record.fields[this.fieldName];
            
            if (value === undefined) {
                return;
            }
            
            const newEntry: ISortedIndexEntry = {
                _id: recordId,
                value,
                fields: record.fields,
            };
            
            // Find the leaf node where this record belongs
            const treeStart = performance.now();
            const leafId = this.findLeafForValue(value);
            const treeTime = performance.now() - treeStart;
            timeInTreeTraversal += treeTime;
            countTreeTraversal++;
            if (!leafId) {
                return;
            }
            
            const leafNode = this.getNode(leafId);
            if (!leafNode || leafNode.children.length > 0) {
                return;
            }
            
            // Get leaf records from cache or load from disk
            let leafRecords = leafRecordsCache.get(leafId);
            if (!leafRecords) {
                const loadStart = performance.now();
                leafRecords = await this.loadLeafRecords(leafId) || [];
                const loadTime = performance.now() - loadStart;
                timeInLoadRecords += loadTime;
                countLoadRecords++;
                leafRecordsCache.set(leafId, leafRecords);
            }
            
            // Binary search to find insertion point
            const binaryStart = performance.now();
            let left = 0;
            let right = leafRecords.length - 1;
            let insertIndex = leafRecords.length;
            
            while (left <= right) {
                const mid = Math.floor((left + right) / 2);
                const compareResult = this.compareValues(value, leafRecords[mid].value);
                if (compareResult < 0) {
                    insertIndex = mid;
                    right = mid - 1;
                } else {
                    left = mid + 1;
                }
            }
            const binaryTime = performance.now() - binaryStart;
            timeInBinarySearch += binaryTime;
            countBinarySearch++;
            
            const spliceStart = performance.now();
            leafRecords.splice(insertIndex, 0, newEntry);
            const spliceTime = performance.now() - spliceStart;
            timeInSplice += spliceTime;
            countSplice++;
            dirtyLeafNodes.add(leafId);
            
            // If inserted at beginning, mark tree structure as changed
            if (insertIndex === 0 && leafRecords.length > 1) {
                treeStructureChanged = true;
            }
            
            this.totalEntries++;
            recordsAdded++;
            
            // If leaf exceeds split threshold, split it (keep in cache, don't save yet)
            if (leafRecords.length > this.pageSize * leafSplitThreshold) {
                if (progressCallback) {
                    progressCallback(`⚠️ SPLITTING page at record ${recordsAdded + 1}: page has ${leafRecords.length} records (threshold: ${Math.floor(this.pageSize * leafSplitThreshold)})`);
                }
                const splitStart = performance.now();
                
                // Split the node (splitLeafNodeInternal modifies leafRecords in place and returns the new node ID and entries)
                const { newNodeId, newEntries } = this.splitLeafNodeInternal(leafId, leafNode, leafRecords);
                
                // Update cache with both split nodes
                // leafRecords now contains the first half (modified in place by splitLeafNode)
                leafRecordsCache.set(leafId, leafRecords);
                leafRecordsCache.set(newNodeId, newEntries);
                dirtyLeafNodes.add(leafId);
                dirtyLeafNodes.add(newNodeId);
                
                const splitTime = performance.now() - splitStart;
                timeInSplit += splitTime;
                countSplit++;
                treeStructureChanged = true;
            }
            
            // Flush at configured batch size
            if (recordsAdded % this.buildBatchSize === 0) {
                await flushDirtyNodes();
            }
        };
       
        // Iterate through shards and process records with checkpoint support
        let shardIndex = 0;
        for await (const shardRecords of collection.iterateShards()) {
            // Skip if shard is already completed
            if (checkpoint.completedShards.includes(shardIndex)) {
                shardIndex++;
                continue;
            }
            
            // Determine starting record index for this shard
            let startIndex = 0;
            if (checkpoint.currentShard === shardIndex) {
                startIndex = checkpoint.currentShardRecordIndex;
            }
            
            // Process records in this shard starting from startIndex
            const recordsArray = Array.from(shardRecords);
            let recordIndex = 0;
            
            for (const record of recordsArray) {
                // Skip records before startIndex
                if (recordIndex < startIndex) {
                    recordIndex++;
                    continue;
                }
                
                // Process record
                await addRecordBatched(record);
                
                // Save checkpoint every 1000 records (not every progress interval to avoid excessive I/O)
                if (recordsAdded % 1000 === 0) {
                    // Only flush if there are actually dirty nodes (avoid unnecessary I/O)
                    if (dirtyLeafNodes.size > 0 || treeStructureChanged) {
                        await flushDirtyNodes();
                    }
                    
                    // Update checkpoint
                    checkpoint.currentShard = shardIndex;
                    checkpoint.currentShardRecordIndex = recordIndex + 1;
                    checkpoint.totalRecordsProcessed = recordsAdded;
                    await this.saveCheckpoint(checkpoint);
                    
                    // Mark as loaded so getPage() works even after abort
                    if (this.rootPageId) {
                        this.loaded = true;
                    }
                }
                
                // Progress callback (may throw to abort build)
                if (recordsAdded % this.buildProgressInterval === 0 && progressCallback) {
                    const totalTime = timeInTreeTraversal + timeInLoadRecords + timeInBinarySearch + timeInSplice + timeInSplit + timeInSave + timeInFlush;
                    const report = [
                        `Indexed ${recordsAdded} records... (cache: ${leafRecordsCache.size} pages, dirty: ${dirtyLeafNodes.size} pages)`,
                        `  Tree traversal: ${(timeInTreeTraversal / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInTreeTraversal / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Load records: ${(timeInLoadRecords / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInLoadRecords / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Binary search: ${(timeInBinarySearch / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInBinarySearch / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Array splice: ${(timeInSplice / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInSplice / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Split nodes: ${(timeInSplit / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInSplit / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Save records: ${(timeInSave / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInSave / totalTime) * 100).toFixed(1) : 0}%)`,
                        `  Flush: ${(timeInFlush / 1000).toFixed(2)}s (${totalTime > 0 ? ((timeInFlush / totalTime) * 100).toFixed(1) : 0}%)`,
                    ].join('\n');
                    progressCallback(report);
                }
                
                recordIndex++;
            }
            
            // Shard complete - mark it and update checkpoint
            checkpoint.completedShards.push(shardIndex);
            checkpoint.currentShard = null;
            checkpoint.currentShardRecordIndex = 0;
            await this.saveCheckpoint(checkpoint);
            
            shardIndex++;
        }
        
        // Final flush of any remaining dirty nodes (into batch state)
        await flushDirtyNodes();
        
        // Save tree nodes and metadata (deferred)
        this.saveTree();
        
        // Flush all deferred writes to storage
        await this.commitChanges();
        
        // Delete checkpoint on successful completion
        await this.deleteCheckpoint();
        
        // Ensure index is marked as loaded
        this.loaded = true;
        
        if (progressCallback) {
            // Calculate averages
            const avgTreeTraversal = countTreeTraversal > 0 ? timeInTreeTraversal / countTreeTraversal : 0;
            const avgLoadRecords = countLoadRecords > 0 ? timeInLoadRecords / countLoadRecords : 0;
            const avgBinarySearch = countBinarySearch > 0 ? timeInBinarySearch / countBinarySearch : 0;
            const avgSplice = countSplice > 0 ? timeInSplice / countSplice : 0;
            const avgSplit = countSplit > 0 ? timeInSplit / countSplit : 0;
            const avgSave = countSave > 0 ? timeInSave / countSave : 0;
            const avgFlush = countFlush > 0 ? timeInFlush / countFlush : 0;
            
            // Find the most expensive operation on average
            const averages = [
                { name: 'Tree traversal', avg: avgTreeTraversal, count: countTreeTraversal },
                { name: 'Load records', avg: avgLoadRecords, count: countLoadRecords },
                { name: 'Binary search', avg: avgBinarySearch, count: countBinarySearch },
                { name: 'Array splice', avg: avgSplice, count: countSplice },
                { name: 'Split nodes', avg: avgSplit, count: countSplit },
                { name: 'Save records', avg: avgSave, count: countSave },
                { name: 'Flush', avg: avgFlush, count: countFlush },
            ];
            
            const mostExpensive = averages.reduce((max, curr) => curr.avg > max.avg ? curr : max, averages[0]);
            
            const report = [
                `Completed indexing ${recordsAdded} records.`,
                ``,
                `Average time per operation:`,
                ...averages.map(a => 
                    `  ${a.name}: ${(a.avg).toFixed(3)}ms (${a.count} operations)${a === mostExpensive ? ' ⚠️ MOST EXPENSIVE' : ''}`
                ),
            ].join('\n');
            
            progressCallback(report);
        }
                       
        this.loaded = true;
    }
    
    // Find the leftmost leaf node in the B-tree
    private findLeftmostLeaf(): string | undefined {
        if (!this.rootPageId) {
            return undefined; 
        }

        let currentId = this.rootPageId;
        let currentNode = this.getNode(currentId);        
        if (!currentNode) {
            return undefined;
        }
        
        // Traverse down the leftmost path to a leaf
        while (currentNode.children.length > 0) {
            currentId = currentNode.children[0];
            currentNode = this.getNode(currentId);            
            if (!currentNode) {
                return undefined;
            }
        }
        
        return currentId;
    }
    
    //
    // Compare values depending on the sort direction and type.
    // If type is 'date', string values will be converted to Date objects before comparison.
    // If type is 'string', values will be compared as strings.
    // If type is 'number', values will be compared as numbers.
    // If type is not set, it will be inferred from the values.
    //
    private compareValues(a: any, b: any): number {
        let valueA = a;
        let valueB = b;
        let inferredType = this.type;
        
        // If type is not set, infer it from the values
        if (!inferredType) {
            // Check if first value is a Date object
            if (a instanceof Date) {
                inferredType = 'date';
            }
            // Check if first value is a number
            else if (typeof a === 'number') {
                inferredType = 'number';
            }
            // Check if first value is a string
            else if (typeof a === 'string') {
                inferredType = 'string';
            }
            
            // Verify both values are compatible types
            if (inferredType === 'date') {
                if (!(b instanceof Date) && typeof b !== 'string') {
                    throw new Error(`Type mismatch in compareValues: first value is Date, second value is ${typeof b},\n${JSON.stringify(a, null, 2)}\n${JSON.stringify(b, null, 2)}`);
                }
            }
            else if (inferredType === 'number') {
                if (typeof b !== 'number') {
                    throw new Error(`Type mismatch in compareValues: first value is number, second value is ${typeof b},\n${JSON.stringify(a, null, 2)}\n${JSON.stringify(b, null, 2)}`);
                }
            }
            else if (inferredType === 'string') {
                if (typeof b !== 'string') {
                    throw new Error(`Type mismatch in compareValues: first value is string, second value is ${typeof b},\n${JSON.stringify(a, null, 2)}\n${JSON.stringify(b, null, 2)}`);
                }
            }
        }
        
        // Convert values based on the specified or inferred type
        if (inferredType === 'date') {
            if (typeof a === 'string') {
                try {
                    valueA = new Date(a);
                } catch (e) {
                    // If parse fails, use original value
                    valueA = a;
                }
            }
            
            if (typeof b === 'string') {
                try {
                    valueB = new Date(b);
                } catch (e) {
                    // If parse fails, use original value
                    valueB = b;
                }
            }
        } else if (inferredType === 'string') {
            // Convert to strings for string comparison
            valueA = String(a);
            valueB = String(b);
            
            // Use localeCompare for proper string comparison
            const compareResult = valueA.localeCompare(valueB);
            if (compareResult < 0) {
                return this.direction === 'asc' ? -1 : 1;
            }
            if (compareResult > 0) {
                return this.direction === 'asc' ? 1 : -1;
            }
            return 0;
        } else if (inferredType === 'number') {
            // Convert to numbers for numeric comparison
            valueA = Number(a);
            valueB = Number(b);
            
            // Handle NaN cases - treat NaN as smaller than any number
            if (isNaN(valueA) && isNaN(valueB)) {
                return 0;
            }
            if (isNaN(valueA)) {
                return this.direction === 'asc' ? -1 : 1;
            }
            if (isNaN(valueB)) {
                return this.direction === 'asc' ? 1 : -1;
            }
        }
        
        if (valueA < valueB) {
            return this.direction === 'asc' ? -1 : 1;
        }
        if (valueA > valueB) {
            return this.direction === 'asc' ? 1 : -1;
        }
        return 0;
    }
    
    // Save leaf records to separate file using serialization library while preserving exact binary format
    //
    // Serializer function for leaf records (without version, as save() handles that)
    //
    private serializeLeafRecords(records: ISortedIndexEntry[], serializer: ISerializer): void {
        // Write record count (4 bytes LE)
        serializer.writeUInt32(records.length);
        
        // Write each record
        for (const entry of records) {
            // Write record ID with length prefix
            const idBuffer = Buffer.from(entry._id, 'utf8');
            serializer.writeBuffer(idBuffer);
            
            // Write value as BSON with length prefix
            serializer.writeBSON({ value: entry.value });
            
            // Write record as BSON with length prefix
            serializer.writeBSON(entry.fields);
        }
    }

    //
    // Stores leaf records in cache and marks the leaf dirty (deferred until commitChanges). Does not write to storage.
    //
    private saveLeafRecords(pageId: string, records: ISortedIndexEntry[]): void {
        this.leafCache.set(pageId, records);
        this.dirtyLeaves.add(pageId);
    }

    //
    // Writes leaf records to storage. Used by commitChanges().
    //
    private async writeLeafRecordsToStorage(pageId: string, records: ISortedIndexEntry[]): Promise<void> {
        const filePath = `${this.indexDirectory}/${pageId}`;
        await save(
            this.storage,
            filePath,
            records,
            1,
            (recordsData, serializer) => this.serializeLeafRecords(recordsData, serializer)
        );
    }
    
    //
    // Deserializer function for leaf records
    //
    private deserializeLeafRecords(deserializer: IDeserializer): ISortedIndexEntry[] {
        // Read record count (4 bytes LE)
        const recordCount = deserializer.readUInt32();
        
        const records: ISortedIndexEntry[] = [];
        
        // Read each record
        for (let i = 0; i < recordCount; i++) {
            // Read record ID with length prefix
            const recordIdBuffer = deserializer.readBuffer();
            const recordId = recordIdBuffer.toString('utf8');
            
            // Read value BSON with length prefix
            const valueObj = deserializer.readBSON<{ value: any }>();
            const value = valueObj.value;
            
            // Read record BSON with length prefix
            const fields = deserializer.readBSON<any>();
            
            records.push({
                _id: recordId,
                value,
                fields,
            });
        }
        
        return records;
    }

    //
    // Loads leaf records: from cache if present, else from storage (and caches for this batch).
    //
    private async loadLeafRecords(pageId: string): Promise<ISortedIndexEntry[] | undefined> {
        const cached = this.leafCache.get(pageId);
        if (cached !== undefined) {
            return cached;
        }
        console.time(`loadLeafRecordsFromStorage ${pageId}`);
        const records = await this.loadLeafRecordsFromStorage(pageId);
        console.timeEnd(`loadLeafRecordsFromStorage ${pageId}`);
        if (records) {
            this.leafCache.set(pageId, records);
        }
        return records;
    }

    //
    // Loads leaf records from storage (used when not in cache).
    //
    private async loadLeafRecordsFromStorage(pageId: string): Promise<ISortedIndexEntry[] | undefined> {
        console.trace(); //fio:
        const filePath = `${this.indexDirectory}/${pageId}`;
        try {
            const records = await load<ISortedIndexEntry[]>(
                this.storage,
                filePath,
                {
                    1: (deserializer) => this.deserializeLeafRecords(deserializer)
                }
            );
            return records;
        }
        catch (error) {
            const fileData = await retry(() => this.storage.read(filePath));
            if (fileData && fileData.length > 0) {
                try {
                    const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);
                    const leafRecordsObj = BSON.deserialize(dataWithoutChecksum);
                    const records = leafRecordsObj.records as ISortedIndexEntry[];
                    return records;
                }
                catch (bsonError) {
                    console.error(`Failed to load leaf records: ${error}`);
                    return undefined;
                }
            }
            return undefined;
        }
    }

    //
    // Marks the leaf file for deletion (deferred until commitChanges). Does not delete from storage yet.
    //
    private deleteLeafRecordsFile(leafId: string): void {
        this.deletedLeaves.add(leafId);
    }

    //
    // Writes all dirty leaves and tree to storage, deletes marked leaves, then clears deferred state.
    //
    async commitChanges(): Promise<void> {
        for (const leafId of this.dirtyLeaves) {
            const records = this.leafCache.get(leafId);
            if (records !== undefined) {
                await this.writeLeafRecordsToStorage(leafId, records);
            }
        }
        if (this.treeChanged) {
            await this.writeTreeToStorage();
        }
        for (const leafId of this.deletedLeaves) {
            const filePath = `${this.indexDirectory}/${leafId}`;
            await this.storage.deleteFile(filePath);
        }
        this.leafCache.clear();
        this.dirtyLeaves.clear();
        this.treeChanged = false;
        this.deletedLeaves.clear();
    }

    // Get a node from cache or map
    private getNode(pageId: string): IBTreeNode | undefined {       
        return this.treeNodes.get(pageId);
    }
     
    //
    // Get a page of records from the collection using the sort index.
    //
    async getPage(pageId?: string): Promise<ISortIndexResult> {
        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }
        
        // If pageId is not provided or invalid, find the leftmost leaf (first page)
        if (!pageId) {
            pageId = this.findLeftmostLeaf();
            if (!pageId) {
                return {
                    records: [],
                    totalRecords: this.totalEntries,
                    currentPageId: '',
                    totalPages: this.totalPages,
                    nextPageId: undefined,
                    previousPageId: undefined
                };
            }
        }
        
        // Get the current page node
        const node = this.getNode(pageId);
        if (!node || node.children.length > 0) { // Not a leaf if it has children
            return {
                records: [],
                totalRecords: this.totalEntries,
                currentPageId: pageId,
                totalPages: this.totalPages,
                nextPageId: undefined,
                previousPageId: undefined
            };
        }
        
        // Get the records from the leaf records file
        const leafRecords = await this.loadLeafRecords(pageId);
        if (!leafRecords) {
            return {
                records: [],
                totalRecords: this.totalEntries,
                currentPageId: pageId,
                totalPages: this.totalPages,
                nextPageId: undefined,
                previousPageId: undefined
            };
        }
        
       
        // Get next page ID from the node's nextLeaf property
        const nextPageId = node.nextLeaf;
        
        // Get previous page ID directly from the node's previousLeaf property
        const previousPageId = node.previousLeaf;
        
        // Return the result with pagination info
        return {
            records: leafRecords,
            totalRecords: this.totalEntries,
            currentPageId: pageId,
            totalPages: this.totalPages,
            nextPageId,
            previousPageId
        };
    }
   
    // Delete the entire index
    async delete(): Promise<void> {
        if (await this.storage.dirExists(this.indexDirectory)) {
            await this.storage.deleteDir(this.indexDirectory);
        }
        
        this.totalEntries = 0;
        this.totalPages = 0;
        this.loaded = false;
        this.treeNodes.clear();
    }
    
    /**
     * Updates a record in the index without rebuilding the entire index
     * If the indexed field value has changed, the record will be removed and added again
     */
    async updateRecord(record: IInternalRecord, oldRecord: IInternalRecord | undefined): Promise<void> {
        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }

        const recordId = record._id;
        const oldValue = oldRecord && oldRecord.fields[this.fieldName];
        
        // First remove old record completely
        let recordRemoved = false;
        if (oldValue !== undefined) {
            // First try to quickly find the specific leaf
            const leafId = this.findLeafForValue(oldValue);
            if (leafId) {
                const leafNode = this.getNode(leafId);
                const leafRecords = await this.loadLeafRecords(leafId);
                
                if (leafNode && leafNode.children.length === 0 && leafRecords) {
                    // Find the entry with matching ID
                    const entryIndex = leafRecords.findIndex(
                        entry => entry._id === recordId
                    );
                    
                    if (entryIndex !== -1) {
                        // Remove the entry
                        leafRecords.splice(entryIndex, 1);
                        
                        // Check if the leaf node is now empty and needs to be removed
                        if (leafRecords.length === 0 && this.totalPages > 1) {
                            // Find the previous and next leaf nodes to update pointers
                            // instead of loading all pages, we need to:
                            // 1. Find previous leaf (by navigating the tree and checking nextLeaf)
                            let prevLeafId: string | undefined = undefined;
                            
                            // Start from the leftmost leaf and follow nextLeaf pointers
                            let currentId = this.findLeftmostLeaf();
                            if (!currentId) {
                                throw new Error(`Left most leaf not found`);
                            }
                            let currentNode = this.getNode(currentId);
                            
                            // Walk the chain until we find the leaf that points to our target
                            while (currentNode && currentId !== leafId) {
                                if (currentNode.nextLeaf === leafId) {
                                    prevLeafId = currentId;
                                    break;
                                }
                                
                                if (!currentNode.nextLeaf) break;
                                currentId = currentNode.nextLeaf;
                                currentNode = this.getNode(currentId);
                            }
                            
                            // If we found a previous leaf, update its nextLeaf pointer
                            if (prevLeafId) {
                                const prevLeafNode = this.getNode(prevLeafId);
                                if (prevLeafNode && prevLeafNode.children.length === 0) {
                                    // Update the next pointer to skip this empty node
                                    prevLeafNode.nextLeaf = leafNode.nextLeaf;
                                    this.saveTree();
                                }
                            }
                            
                            // Update the previousLeaf pointer of the next node
                            if (leafNode.nextLeaf) {
                                const nextLeafNode = this.getNode(leafNode.nextLeaf);
                                if (nextLeafNode && nextLeafNode.children.length === 0) {
                                    nextLeafNode.previousLeaf = prevLeafId;
                                    this.saveTree();
                                }
                            }
                            
                            // Remove leaf records file
                            this.deleteLeafRecordsFile(leafId);
                            
                            // Remove the node from the treeNodes map
                            this.treeNodes.delete(leafId);
                            
                            // Decrement total pages since we're effectively removing this page
                            this.totalPages--;
                        } 
                        else {
                            // Update leaf records
                            this.saveLeafRecords(leafId, leafRecords);
                        }
                        
                        // Decrement total entries
                        this.totalEntries--;
                        recordRemoved = true;
                    }
                }
            }
            
            // If we didn't find the record in the expected leaf, we need to check all pages with the same value
            if (!recordRemoved) {
                // We need to find the pages that might contain records with this value
                // First, get all records with this value
                const matchingValues = await this.findByValue(oldValue);
                if (matchingValues.length > 0) {
                    // Start with the leftmost leaf and traverse the chain
                    let currentId = this.findLeftmostLeaf();
                    if (!currentId) {
                        throw new Error(`Left most leaf not found.`);
                    }
                    let currentNode = this.getNode(currentId);
                    
                    // Keep track of previous node for updating nextLeaf pointers
                    let prevNodeId: string | undefined = undefined;
                    
                    while (currentNode) {
                        if (currentNode.children.length === 0) {
                            const leafRecords = await this.loadLeafRecords(currentId);
                            if (leafRecords) {
                                // Find the entry with matching ID
                                const entryIndex = leafRecords.findIndex(
                                    entry => entry._id === recordId
                                );
                                
                                if (entryIndex !== -1) {
                                    // Remove the entry
                                    leafRecords.splice(entryIndex, 1);
                                    
                                    // Check if the leaf node is now empty and needs to be removed
                                    if (leafRecords.length === 0 && this.totalPages > 1) {
                                        // If we have a previous node, update its nextLeaf pointer
                                        if (prevNodeId) {
                                            const prevNode = this.getNode(prevNodeId);
                                            if (prevNode && prevNode.children.length === 0) {
                                                prevNode.nextLeaf = currentNode.nextLeaf;
                                                this.saveTree();
                                            }
                                        }
                                        
                                        // Update the previousLeaf pointer of the next node
                                        if (currentNode.nextLeaf) {
                                            const nextNode = this.getNode(currentNode.nextLeaf);
                                            if (nextNode && nextNode.children.length === 0) {
                                                nextNode.previousLeaf = prevNodeId;
                                                this.saveTree();
                                            }
                                        }
                                        
                                        // Remove leaf records file
                                        this.deleteLeafRecordsFile(currentId);
                                        
                                        // Remove the node from the treeNodes map
                                        this.treeNodes.delete(currentId);
                                        
                                        // Decrement total pages since we're effectively removing this page
                                        this.totalPages--;
                                    } else {
                                        // Update leaf records
                                        this.saveLeafRecords(currentId, leafRecords);
                                    }
                                    
                                    // Decrement total entries
                                    this.totalEntries--;
                                    recordRemoved = true;
                                    break; // Found and removed the record
                                }
                            }
                        }
                        
                        // Move to the next leaf
                        if (!currentNode.nextLeaf) break;
                        prevNodeId = currentId;
                        currentId = currentNode.nextLeaf;
                        currentNode = this.getNode(currentId);
                    }
                }
            }
        }
        
        // Now add the record with the new value
        await this.addRecord(record);
    }
    
    /**
     * Deletes a record from the index without rebuilding the entire index
     * @param recordId The ID of the record to delete
     * @param value The value of the indexed field, used to help locate the record
     */
    async deleteRecord(recordId: string, oldRecord: IInternalRecord): Promise<void> {

        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }

        const value = oldRecord.fields[this.fieldName];
        if (value === undefined) {
            // Just assume the record is not indexed.
            return;
        }
        
        let recordDeleted = false;
        
        // First try to find the record in the expected leaf
        const leafId = this.findLeafForValue(value);
        if (leafId) {
            const leafNode = this.getNode(leafId);
            const leafRecords = await this.loadLeafRecords(leafId);
            
            if (leafNode && leafNode.children.length === 0 && leafRecords) {
                // Find the entry with matching ID
                const entryIndex = leafRecords.findIndex(
                    entry => entry._id === recordId
                );
                
                if (entryIndex !== -1) {
                    // Remove the entry
                    leafRecords.splice(entryIndex, 1);
                    
                    // If this was the first entry and there are more entries,
                    // update the key in parent nodes
                    if (entryIndex === 0 && leafRecords.length > 0) {
                        await this.updateKeyInParents(leafId, value, leafRecords[0].value);
                    }
                    
                    // Check if the leaf node is now empty and needs to be removed
                    if (leafRecords.length === 0 && this.totalPages > 1) {
                        // Find the previous leaf (by navigating the tree and checking nextLeaf)
                        let prevLeafId = '';
                        
                        // Start from the leftmost leaf and follow nextLeaf pointers
                        let currentId = this.findLeftmostLeaf();
                        if (!currentId) {
                            throw new Error(`Left most leaf not found`);
                        }

                        let currentNode = this.getNode(currentId);
                        
                        // Walk the chain until we find the leaf that points to our target
                        while (currentNode && currentId !== leafId) {
                            if (currentNode.nextLeaf === leafId) {
                                prevLeafId = currentId;
                                break;
                            }
                            
                            if (!currentNode.nextLeaf) break;
                            currentId = currentNode.nextLeaf;
                            currentNode = this.getNode(currentId);
                        }
                        
                        // If we found a previous leaf, update its nextLeaf pointer
                        if (prevLeafId) {
                            const prevLeafNode = this.getNode(prevLeafId);
                            if (prevLeafNode && prevLeafNode.children.length === 0) {
                                // Update the next pointer to skip this empty node
                                prevLeafNode.nextLeaf = leafNode.nextLeaf;
                                this.saveTree();
                            }
                        }
                        
                        // Update the previousLeaf pointer of the next node
                        if (leafNode.nextLeaf) {
                            const nextLeafNode = this.getNode(leafNode.nextLeaf);
                            if (nextLeafNode && nextLeafNode.children.length === 0) {
                                nextLeafNode.previousLeaf = prevLeafId;
                                this.saveTree();
                            }
                        }
                        
                        // Remove leaf records file
                        this.deleteLeafRecordsFile(leafId);
                        
                        // Remove the node from the treeNodes map
                        this.treeNodes.delete(leafId);
                        
                        // Decrement total pages since we're effectively removing this page
                        this.totalPages--;
                    } else {
                        // Update the leaf records
                        this.saveLeafRecords(leafId, leafRecords);
                    }
                    
                    // Decrement total entries
                    this.totalEntries--;
                    
                    recordDeleted = true;
                }
            }
        }
        
        // If we didn't find the record in the expected leaf, try other leaves with matching values
        if (!recordDeleted) {
            // First, get all records with this value
            const matchingValues = await this.findByValue(value);
            
            // If there are records with this value, we need to search through the leaves
            if (matchingValues.length > 0) {
                // Start with the leftmost leaf and traverse the chain
                let currentId = this.findLeftmostLeaf();
                if (!currentId) {
                    throw new Error(`Left most leaf not found.`);
                }

                let currentNode = this.getNode(currentId);
                
                // Keep track of previous node for updating nextLeaf pointers
                let prevNodeId = '';
                
                while (currentNode) {
                    if (currentNode.children.length === 0) {
                        const leafRecords = await this.loadLeafRecords(currentId);
                        if (leafRecords) {
                            // Find the entry with matching ID
                            const entryIndex = leafRecords.findIndex(
                                entry => entry._id === recordId
                            );
                            
                            if (entryIndex !== -1) {
                                // Remove the entry
                                leafRecords.splice(entryIndex, 1);
                                
                                // If this was the first entry and there are more entries,
                                // update the key in parent nodes
                                if (entryIndex === 0 && leafRecords.length > 0) {
                                    await this.updateKeyInParents(currentId, value, leafRecords[0].value);
                                }
                                
                                // Check if the leaf node is now empty and needs to be removed
                                if (leafRecords.length === 0 && this.totalPages > 1) {
                                    // If we have a previous node, update its nextLeaf pointer
                                    if (prevNodeId) {
                                        const prevNode = this.getNode(prevNodeId);
                                        if (prevNode && prevNode.children.length === 0) {
                                            prevNode.nextLeaf = currentNode.nextLeaf;
                                            this.saveTree();
                                        }
                                    }
                                    
                                    // Update the previousLeaf pointer of the next node
                                    if (currentNode.nextLeaf) {
                                        const nextNode = this.getNode(currentNode.nextLeaf);
                                        if (nextNode && nextNode.children.length === 0) {
                                            nextNode.previousLeaf = prevNodeId;
                                            this.saveTree();
                                        }
                                    }
                                    
                                    // Remove leaf records file
                                    this.deleteLeafRecordsFile(currentId);
                                    
                                    // Remove the node from the treeNodes map
                                    this.treeNodes.delete(currentId);
                                    
                                    // Decrement total pages since we're effectively removing this page
                                    this.totalPages--;
                                } else {
                                    // Update the leaf records
                                    this.saveLeafRecords(currentId, leafRecords);
                                }
                                
                                // Decrement total entries
                                this.totalEntries--;
                                
                                recordDeleted = true;
                                break; // Found and removed the record
                            }
                        }
                    }
                    
                    // Move to the next leaf
                    if (!currentNode.nextLeaf) break;
                    prevNodeId = currentId;
                    currentId = currentNode.nextLeaf;
                    currentNode = this.getNode(currentId);
                }
            }
        }
        
        // Update metadata if we found and removed a record
        if (recordDeleted) {
            this.saveTree();
        }
    }
    
    /**
     * Finds the leaf node that would contain a value
     */
    private findLeafForValue(value: any): string | undefined {
        if (!this.rootPageId) {
            return undefined;
        }
        
        const rootNode = this.getNode(this.rootPageId);
        if (!rootNode) {
            return undefined;
        }
        
        let currentId = this.rootPageId;
        let currentNode = rootNode;
        
        // Traverse down to leaf
        while (currentNode.children.length > 0) {
            // Find the appropriate child based on the value
            let childIndex = 0;
            
            for (let i = 0; i < currentNode.keys.length; i++) {
                if (this.compareValues(value, currentNode.keys[i]) > 0) {
                    childIndex = i + 1;
                } 
                else {
                    break;
                }
            }
            
            if (childIndex >= currentNode.children.length) {
                childIndex = currentNode.children.length - 1;
            }
            
            if (currentNode.children.length === 0) {
                break;
            }
            
            currentId = currentNode.children[childIndex];
            const nextNode = this.getNode(currentId);            
            if (!nextNode) {
                return undefined;
            }

            currentNode = nextNode;
        }
        
        return currentId;
    }
    
    /**
     * Updates a key value in parent nodes when the first entry in a leaf changes
     * This is essential for maintaining the B-tree structure when the minimum key in a leaf node changes
     * Using parent references for efficient traversal
     */
    private async updateKeyInParents(nodeId: string, oldKey: any, newKey: any): Promise<void> {
        if (!nodeId) return;
        
        const node = this.getNode(nodeId);
        if (!node || !node.parentId) {
            return;
        }
               
        const parentNode = this.getNode(node.parentId);
        if (!parentNode) {
            return;
        }
        
        // Find the index of the key that references this node
        const childIndex = parentNode.children.indexOf(nodeId);
        
        // If this isn't the leftmost child (i > 0), it has a key in the parent
        if (childIndex > 0 && this.compareValues(parentNode.keys[childIndex - 1], oldKey) === 0) {
            parentNode.keys[childIndex - 1] = newKey;
            this.saveTree();
        }
        
        // Recursively update parent nodes if needed
        await this.updateKeyInParents(node.parentId, oldKey, newKey);
    }
    
    /**
     * Adds a new record to the index without rebuilding the entire index
     */
    async addRecord(record: IInternalRecord): Promise<void> {       
        
        const recordId = record._id;
        const value = record.fields[this.fieldName];
        
        // If the field doesn't exist in the record, don't add it to the index
        if (value === undefined) {
            return;
        }
        
        // Create the new entry
        const newEntry: ISortedIndexEntry = {
            _id: recordId,
            value,
            fields: record.fields,
        };
        
        // Find the leaf node where this record belongs
        const leafId = this.findLeafForValue(value);
        if (!leafId) {
            return; // Should not happen with a properly initialized tree
        }
        
        const leafNode = this.getNode(leafId);
        if (!leafNode || leafNode.children.length > 0) {
            return;
        }
        
        // Get the leaf records
        let leafRecords = await this.loadLeafRecords(leafId) || [];
        
        // Insert the entry in the correct position using binary search
        let left = 0;
        let right = leafRecords.length - 1;
        let insertIndex = leafRecords.length; // Default to end of array

        // Binary search to find insertion point
        while (left <= right) {
            const mid = Math.floor((left + right) / 2);
            const compareResult = this.compareValues(value, leafRecords[mid].value);            
            if (compareResult < 0) {
                // New value should go before the middle element
                // (compareValues already accounts for direction)
                insertIndex = mid;
                right = mid - 1;
            } else {
                // New value should go after the middle element
                left = mid + 1;
            }
        }
        
        // Insert the entry at the found position
        leafRecords.splice(insertIndex, 0, newEntry);
        
        // If this was inserted at the beginning, update keys in parent nodes
        if (insertIndex === 0 && leafRecords.length > 1) {
            await this.updateKeyInParents(leafId, leafRecords[1].value, value);
        }
        
        // If the leaf is now too large, split it
        if (leafRecords.length > this.pageSize * leafSplitThreshold) {
            await this.splitLeafNode(leafId, leafNode, leafRecords); // Save immediately in regular addRecord
        } 
        else {
            // Just update the leaf records
            this.saveLeafRecords(leafId, leafRecords);
        }
        
        // Increment total entries
        this.totalEntries++;
        
        // Update metadata
        this.saveTree();
    }
    
    /**
     * Internal function that splits a leaf node without saving to disk
     * @returns An object with the new node ID and the new entries (second half of the split)
     */
    private splitLeafNodeInternal(nodeId: string, node: IBTreeNode, records: ISortedIndexEntry[]): { newNodeId: string; newEntries: ISortedIndexEntry[] } {
        if (node.children.length > 0) {
            throw new Error('Cannot split internal node as leaf node');
        }
        
        // Ensure entries are properly sorted first
        records.sort((a, b) => this.compareValues(a.value, b.value));
        
        // Split point
        const splitIndex = Math.floor(records.length / 2);
        
        // Create new leaf node with the second half
        const newEntries = records.splice(splitIndex);
        const newNodeId = this.uuidGenerator.generate();
     
        const newNode: IBTreeNode = {
            // Node is a leaf (children array is empty)
            keys: [],
            children: [],
            nextLeaf: node.nextLeaf,
            previousLeaf: nodeId,
            parentId: node.parentId, // Copy parent from original node
        };
        this.treeNodes.set(newNodeId, newNode);
        
        // Update pointers in the original node
        node.nextLeaf = newNodeId;
        
        // Update the previousLeaf pointer of the node that comes after the new node
        if (newNode.nextLeaf) {
            const nextNode = this.getNode(newNode.nextLeaf);
            if (nextNode && nextNode.children.length === 0) {
                nextNode.previousLeaf = newNodeId;
            }
        }
        
        // Create or update parent node to maintain the B-tree structure
        if (nodeId === this.rootPageId && node.children.length === 0) {
            // If we're splitting the root, we need to create a new root
            const newRootId = this.uuidGenerator.generate();
            const newRoot: IBTreeNode = {
                // Internal node (has children)
                keys: [newEntries[0].value],
                children: [nodeId, newNodeId],
                parentId: undefined,
            };
            this.treeNodes.set(newRootId, newRoot);
            
            // Update parent references for children
            node.parentId = newRootId;
            newNode.parentId = newRootId;
            
            // Update the root page ID
            this.rootPageId = newRootId;
        }
        else if (node.parentId) {
            // Non-root node splitting - we need to insert the new node into the parent
            const parentId = node.parentId;
            const parentNode = this.getNode(parentId);
            
            if (parentNode && parentNode.children.length > 0) {
                // Find the position of the original node in the parent's children array
                const childIndex = parentNode.children.indexOf(nodeId);
                
                if (childIndex !== -1) {
                    // Insert the new node after the original node in the parent's children array
                    parentNode.children.splice(childIndex + 1, 0, newNodeId);
                    
                    // Insert the separator key (first key in new leaf) in the parent's keys array
                    parentNode.keys.splice(childIndex, 0, newEntries[0].value);
                    
                    // If the parent node is now too large, we need to split it too
                    if (parentNode.keys.length > (this.keySize * splitKeysThreshold)) {
                        this.splitInternalNode(parentId, parentNode);
                    }
                }
            }
        }
        
        // Increment total pages since we created a new leaf page
        this.totalPages++;
        
        return { newNodeId, newEntries };
    }

    /**
     * Splits a leaf node when it gets too large and saves to disk
     */
    private async splitLeafNode(nodeId: string, node: IBTreeNode, records: ISortedIndexEntry[]): Promise<void> {
        const { newNodeId, newEntries } = this.splitLeafNodeInternal(nodeId, node, records);
        
        // Save leaf records for both nodes
        this.saveLeafRecords(nodeId, records);
        this.saveLeafRecords(newNodeId, newEntries);
        
        // Save both nodes
        this.saveTree();
    }
    
    // Find records by exact value using binary search on the sorted index
    async findByValue(value: any): Promise<ISortedIndexEntry[]> {
        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }
        
        const matchingEntries: ISortedIndexEntry[] = [];
        
        // First try to find the specific leaf that should contain this value
        const leafId = this.findLeafForValue(value);
        if (!leafId) {
            // No leaf found that might contain this value
            return [];
        }
        
        // Process the initial leaf node
        const leafNode = this.getNode(leafId);
        const leafRecords = await this.loadLeafRecords(leafId);
        
        if (leafNode && leafNode.children.length === 0 && leafRecords) {
            // Find all entries with the exact value
            const matches = leafRecords.filter(entry => entry.value === value);
            
            if (matches.length > 0) {
                matchingEntries.push(...matches);
                
                // Due to B-tree split operations, records with the same value could potentially
                // be in different leaf nodes. We need to check adjacent nodes.
                
                // Check forward in the linked list for additional matches
                let nextId = leafNode.nextLeaf;
                while (nextId) {
                    const nextNode = this.getNode(nextId);
                    if (!nextNode || nextNode.children.length > 0) break;
                    
                    const nextRecords = await this.loadLeafRecords(nextId);
                    if (!nextRecords || nextRecords.length === 0) break;
                    
                    // Find any matching records in this leaf
                    const nextMatches = nextRecords.filter(entry => entry.value === value);
                    
                    if (nextMatches.length > 0) {
                        matchingEntries.push(...nextMatches);
                    } else if (this.compareValues(nextRecords[0].value, value) > 0) {
                        // If first value > search value, we're done looking forward
                        // compareValues already accounts for direction
                        break;
                    }
                    
                    nextId = nextNode.nextLeaf;
                }
                
                // Check backward in the linked list for additional matches
                let prevId = leafNode.previousLeaf;
                while (prevId) {
                    const prevNode = this.getNode(prevId);
                    if (!prevNode || prevNode.children.length > 0) break;
                    
                    const prevRecords = await this.loadLeafRecords(prevId);
                    if (!prevRecords || prevRecords.length === 0) break;
                    
                    // Find any matching records in this leaf
                    const prevMatches = prevRecords.filter(entry => entry.value === value);
                    
                    if (prevMatches.length > 0) {
                        matchingEntries.push(...prevMatches);
                    } else if (this.compareValues(prevRecords[prevRecords.length - 1].value, value) < 0) {
                        // If last value < search value, we're done looking backward
                        // compareValues already accounts for direction
                        break;
                    }
                    
                    prevId = prevNode.previousLeaf;
                }
            }
        }
        
        // If we still haven't found any matching records, we need to search all leaves
        // This is necessary because the B-tree structure might have sent us to the wrong leaf
        // especially in test scenarios with small datasets
        if (matchingEntries.length === 0) {
            // Start with the leftmost leaf
            let currentId = this.findLeftmostLeaf();            
            while (currentId) {
                const currentNode = this.getNode(currentId);
                if (!currentNode || currentNode.children.length > 0) break;
                
                const currentRecords = await this.loadLeafRecords(currentId);
                if (!currentRecords) {
                    if (!currentNode.nextLeaf) break;
                    currentId = currentNode.nextLeaf;
                    continue;
                }
                
                // Check each record
                const matches = currentRecords.filter(entry => entry.value === value);
                
                if (matches.length > 0) {
                    matchingEntries.push(...matches);
                }
                
                if (!currentNode.nextLeaf) break;
                currentId = currentNode.nextLeaf;
            }
        }
        
        // Return the matching records
        return matchingEntries;
    }
    
    // Find records by range query using optimized leaf traversal.
    async findByRange(options: IRangeOptions): Promise<ISortedIndexEntry[]> {
        const {
            min = null,
            max = null,
            minInclusive = true,
            maxInclusive = true
        } = options;
        
        // At least one bound must be specified
        if (min === null && max === null) {
            throw new Error('At least one of min or max must be specified for range query');
        }
        
        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }
        
        const matchingRecords: ISortedIndexEntry[] = [];
        
        // Find the leaf node where we should start the traversal
        // If min is specified, start from the leaf that would contain min
        // Otherwise, start from the leftmost leaf
        let startLeafId: string | undefined;
        if (min !== null) {
            startLeafId = this.findLeafForValue(min);
            if (!startLeafId) {
                return matchingRecords;
            }
        } else {
            startLeafId = this.findLeftmostLeaf();
            if (!startLeafId) {
                return matchingRecords;
            }
        }
        
        // Traverse the linked list of leaf nodes, starting from startLeafId
        let currentId = startLeafId;
        let continueTraversal = true;
        
        while (currentId && continueTraversal) {
            const node = this.getNode(currentId);
            if (!node || node.children.length > 0) {
                break;
            }
            
            const leafRecords = await this.loadLeafRecords(currentId);
            if (!leafRecords) {
                if (!node.nextLeaf) break;
                currentId = node.nextLeaf;
                continue;
            }
            
            let foundMatchInLeaf = false;
            let exceedsMaxBound = false;
            
            // Check each record in the leaf
            for (const entry of leafRecords) {
                // Check min bound
                if (min !== null) {
                    const compareMin = this.compareValues(entry.value, min);
                    if (minInclusive ? compareMin < 0 : compareMin <= 0) {
                        continue; // Skip entries below min
                    }
                }
                
                // Check max bound
                if (max !== null) {
                    const compareMax = this.compareValues(entry.value, max);
                    if (maxInclusive ? compareMax > 0 : compareMax >= 0) {
                        // In ascending order, once we exceed the max bound, all subsequent entries
                        // in this and future leaves will also exceed it, so we can stop traversal
                        // Only stop traversal if the value is strictly greater than max (not equal)
                        if (this.direction === 'asc' && compareMax > 0) {
                            exceedsMaxBound = true;
                            break;
                        }
                        continue; // Skip entries above max
                    }
                }
                
                // If we reach here, the entry is within the range
                matchingRecords.push(entry);
                foundMatchInLeaf = true;
            }
            
            // If we've exceeded the max bound in ascending order, we can stop traversal
            if (exceedsMaxBound) {
                break;
            }
            
            // If we've found matches but the last entry is below the min,
            // all subsequent leaves will also be below min, so we can stop
            // This applies regardless of direction because compareValues handles the direction
            if (foundMatchInLeaf && max === null && 
                leafRecords.length > 0 && min !== null) {
                const lastEntry = leafRecords[leafRecords.length - 1];
                const compareMin = this.compareValues(lastEntry.value, min);
                if (compareMin < 0) {
                    break;
                }
            }
            
            // Move to the next leaf
            if (!node.nextLeaf) {
                break;
            }
            currentId = node.nextLeaf;
        }
        
        // Results should already be in correct order due to in-order traversal
        // but sort them to be absolutely certain
        matchingRecords.sort((a, b) => this.compareValues(a.fields[this.fieldName], b.fields[this.fieldName]));
        
        return matchingRecords;
    }

    /**
     * Splits an internal node when it gets too large
     */
    private splitInternalNode(nodeId: string, node: IBTreeNode): void {
        if (node.children.length === 0) {
            return; // Only process internal nodes
        }
        
        // Find the middle index
        const middleIndex = Math.floor(node.keys.length / 2);
        
        // The middle key will be promoted to the parent
        const middleKey = node.keys[middleIndex];
        
        // Create a new internal node for the right half
        const newNodeId = this.uuidGenerator.generate();
        const newNode: IBTreeNode = {
            // Internal node (has children)
            keys: node.keys.splice(middleIndex + 1), // Take keys after the middle
            children: node.children.splice(middleIndex + 1), // Take children after the middle
            parentId: node.parentId,
        };
        this.treeNodes.set(newNodeId, newNode);
        
        // Remove the middle key from the original node (it goes up to the parent)
        node.keys.splice(middleIndex, 1);
        
        // Update parent references for all children of the new node
        for (const childId of newNode.children) {
            const childNode = this.getNode(childId);
            if (childNode) {
                childNode.parentId = newNodeId;
            }
        }
        
        // If this is the root node, create a new root
        if (nodeId === this.rootPageId) {
            const newRootId = this.uuidGenerator.generate();
            const newRoot: IBTreeNode = {
                // Internal node (has children)
                keys: [middleKey],
                children: [nodeId, newNodeId],
                parentId: undefined,
            };
            this.treeNodes.set(newRootId, newRoot);
            
            // Update parent references
            node.parentId = newRootId;
            newNode.parentId = newRootId;
                        
            // Update the root page ID
            this.rootPageId = newRootId;
        } 
        else if (node.parentId) {
            // Insert into parent node
            const parentId = node.parentId;
            const parentNode = this.getNode(parentId);
            
            if (parentNode && parentNode.children.length > 0) {
                // Find the position of the original node in the parent's children array
                const childIndex = parentNode.children.indexOf(nodeId);
                
                if (childIndex !== -1) {
                    // Insert the new node after the original node
                    parentNode.children.splice(childIndex + 1, 0, newNodeId);
                    
                    // Insert the middle key
                    parentNode.keys.splice(childIndex, 0, middleKey);
                                        
                    // Check if the parent needs to be split
                    if (parentNode.keys.length > (this.keySize * splitKeysThreshold)) {
                        this.splitInternalNode(parentId, parentNode);
                    }
                }
            }
        }
    }

    /**
     * Helper function to format a value, truncating to first 4 and last 4 characters
     */
    private formatValueForDisplay(value: any): string {
        const str = String(value);
        if (str.length > 8) {
            return `${str.slice(0, 4)}-${str.slice(-4)}`;
        }
        return str;
    }

    /**
     * Visualizes the B-tree structure for debugging purposes
     * Returns a string representation of the tree
     */
    async visualizeTree(): Promise<string> {
       
        if (!this.rootPageId) {
            return "Empty tree";
        }
        
        const lines: string[] = [`B-Tree Index for ${this.fieldName} (${this.direction})`];
        lines.push(`Total entries: ${this.totalEntries}, Total pages: ${this.totalPages}`);
        lines.push("------------------------");
        
        // Recursive function to visualize nodes
        const visualizeNode = async (nodeId: string, level: number): Promise<void> => {
            const node = this.getNode(nodeId);
            if (!node) {
                return;
            }
            
            const indent = "  ".repeat(level);
            const nodeType = node.children.length === 0 ? "LEAF" : "INTERNAL";
            
            const shortNodeId = `${nodeId.slice(0, 4)}-${nodeId.slice(-4)}`;
            lines.push(`${indent}[${shortNodeId}] ${nodeType} NODE`);
            
            if (node.keys.length > 0) {
                lines.push(`${indent} Keys: ${node.keys.map(k => this.formatValueForDisplay(k)).join(', ')}`);
            }
            
            if (node.children.length === 0) {
                const records = await this.loadLeafRecords(nodeId);
                if (records && records.length > 0) {
                    lines.push(`${indent} Records: ${records.length}`);
                    // Show first few records for preview
                    const preview = records.slice(0, 3).map(r => this.formatValueForDisplay(r.value)).join(', ');
                    if (records.length > 3) {
                        lines.push(`${indent} Values: ${preview}, ...`);
                    } 
                    else {
                        lines.push(`${indent} Values: ${preview}`);
                    }
                    
                    const shortPrevLeaf = node.previousLeaf ? `${node.previousLeaf.slice(0, 4)}-${node.previousLeaf.slice(-4)}` : 'undefined';
                    lines.push(`${indent} Previous leaf: ${shortPrevLeaf}`);

                    const shortNextLeaf = node.nextLeaf ? `${node.nextLeaf.slice(0, 4)}-${node.nextLeaf.slice(-4)}` : 'undefined';
                    lines.push(`${indent} Next leaf: ${shortNextLeaf}`);
                }
            } 
            else {
                // For internal nodes, recursively visualize children
                for (const childId of node.children) {
                    await visualizeNode(childId, level + 1);
                }
            }
        };
        
        // Start visualization from the root
        await visualizeNode(this.rootPageId, 0);
        
        return lines.join('\n');
    }
    
    // Analyze the tree structure and return statistics about keys per node
    async analyzeTreeStructure(): Promise<{
        totalNodes: number;
        leafNodes: number;
        internalNodes: number;
        minKeysPerNode: number;
        maxKeysPerNode: number;
        avgKeysPerNode: number;
        nodeKeyDistribution: { nodeId: string; keyCount: number; isLeaf: boolean }[];
        leafStats: {
            minRecordsPerLeaf: number;
            maxRecordsPerLeaf: number;
            avgRecordsPerLeaf: number;
        };
        internalStats: {
            minKeysPerInternal: number;
            maxKeysPerInternal: number;
            avgKeysPerInternal: number;
        };
    }> {
        if (!this.loaded) {
            throw new Error('Sort index is not loaded. Call load/build first.');
        }
        
        if (!this.rootPageId) {
            return {
                totalNodes: 0,
                leafNodes: 0,
                internalNodes: 0,
                minKeysPerNode: 0,
                maxKeysPerNode: 0,
                avgKeysPerNode: 0,
                nodeKeyDistribution: [],
                leafStats: {
                    minRecordsPerLeaf: 0,
                    maxRecordsPerLeaf: 0,
                    avgRecordsPerLeaf: 0
                },
                internalStats: {
                    minKeysPerInternal: 0,
                    maxKeysPerInternal: 0,
                    avgKeysPerInternal: 0
                }
            };
        }
        
        const nodeKeyDistribution: { nodeId: string; keyCount: number; isLeaf: boolean }[] = [];
        let totalKeys = 0;
        let minKeys = Number.MAX_SAFE_INTEGER;
        let maxKeys = 0;
        let leafNodes = 0;
        let internalNodes = 0;
        
        // Separate stats for leaf and internal nodes
        let leafTotalRecords = 0;
        let leafMinRecords = Number.MAX_SAFE_INTEGER;
        let leafMaxRecords = 0;
        
        let internalTotalKeys = 0;
        let internalMinKeys = Number.MAX_SAFE_INTEGER;
        let internalMaxKeys = 0;
        
        // Traverse all nodes in deterministic order
        const sortedNodes = Array.from(this.treeNodes.entries()).sort(([a], [b]) => a.localeCompare(b));
        for (const [nodeId, node] of sortedNodes) {
            const isLeaf = node.children.length === 0;
            let keyCount = node.keys.length;
            
            // For leaf nodes, also count the records
            if (isLeaf) {
                const records = await this.loadLeafRecords(nodeId);
                if (records) {
                    keyCount = records.length;
                    leafTotalRecords += keyCount;
                    leafMinRecords = Math.min(leafMinRecords, keyCount);
                    leafMaxRecords = Math.max(leafMaxRecords, keyCount);
                }
                leafNodes++;
            } else {
                // Internal node - count keys
                internalTotalKeys += keyCount;
                internalMinKeys = Math.min(internalMinKeys, keyCount);
                internalMaxKeys = Math.max(internalMaxKeys, keyCount);
                internalNodes++;
            }
            
            nodeKeyDistribution.push({ nodeId, keyCount, isLeaf });
            totalKeys += keyCount;
            minKeys = Math.min(minKeys, keyCount);
            maxKeys = Math.max(maxKeys, keyCount);
        }
        
        const totalNodes = this.treeNodes.size;
        const avgKeysPerNode = totalNodes > 0 ? totalKeys / totalNodes : 0;
        
        // Calculate averages for leaf and internal nodes
        const avgRecordsPerLeaf = leafNodes > 0 ? leafTotalRecords / leafNodes : 0;
        const avgKeysPerInternal = internalNodes > 0 ? internalTotalKeys / internalNodes : 0;
        
        return {
            totalNodes,
            leafNodes,
            internalNodes,
            minKeysPerNode: minKeys === Number.MAX_SAFE_INTEGER ? 0 : minKeys,
            maxKeysPerNode: maxKeys,
            avgKeysPerNode,
            nodeKeyDistribution,
            leafStats: {
                minRecordsPerLeaf: leafMinRecords === Number.MAX_SAFE_INTEGER ? 0 : leafMinRecords,
                maxRecordsPerLeaf: leafMaxRecords,
                avgRecordsPerLeaf
            },
            internalStats: {
                minKeysPerInternal: internalMinKeys === Number.MAX_SAFE_INTEGER ? 0 : internalMinKeys,
                maxKeysPerInternal: internalMaxKeys,
                avgKeysPerInternal
            }
        };
    }
}