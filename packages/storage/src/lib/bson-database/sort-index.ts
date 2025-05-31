//
// Implements a sorted index for a BSON collection with support for pagination
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IRecord, IBsonCollection } from './collection';
import { IStorage } from '../storage';
import { retry } from 'utils';
// let id = 0;

function makeId() {
    return crypto.randomUUID();

    //
    // Compact id for readability.
    //
    // const id = crypto.randomUUID();
    // return id.slice(0, 2) + "-" + id.slice(-2);

    //
    // Simple id for testing.
    //
    // ++id;
    // return `id-${id}`;
}

// Constants for save debouncing
const maxSaveDelayMs = 10_000;

export interface ISortedIndexEntry<RecordT> {
    // The ID of the record
    recordId: string; //TODO: this should be a UUID buffer type.

    // The value used for sorting
    value: any;
    
    // The complete record - for faster retrieval without loading from collection
    record: RecordT;
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
    direction: 'asc' | 'desc';

    // Number of records per page
    pageSize?: number;
    
    // Maximum number of keys per internal node
    keySize?: number;
    
    // Optional type for value conversion before comparison
    // Supports 'date' for ISO string date parsing, 'string' for string comparison, 'number' for numeric comparison
    type?: 'date' | 'string' | 'number';
}

export interface ISortResult<RecordT> {
    // Records for the requested page
    records: RecordT[];

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

// B-tree node interface
interface IBTreeNode {
    keys: any[];  // Values that divide ranges
    children: string[];  // For internal nodes, pageIds of children (empty array means this is a leaf node)
    nextLeaf?: string;  // For leaf nodes, pageId of next leaf for sequential scans
    previousLeaf?: string;  // For leaf nodes, pageId of previous leaf for reverse traversal
    parentId?: string;  // Reference to parent node
    // A node is a leaf if children.length === 0, and NOT a leaf if children.length > 0
}

export class SortIndex<RecordT extends IRecord> {
    private storage: IStorage;
    private indexDirectory: string;
    private fieldName: string;
    private direction: 'asc' | 'desc';
    private pageSize: number;
    private keySize: number;
    private totalEntries: number = 0;
    private totalPages: number = 0; // Tracks only leaf nodes (user-facing pages)
    private loaded: boolean = false;
    private lastUpdatedAt: Date | undefined;
    private saving: boolean = false; // Flag to prevent concurrent saves.
    private dirty: boolean = false;
    private rootPageId: string | undefined;
    private type?: 'date' | 'string' | 'number'; // Optional type for value conversion
    
    // Path to the single file that contains all tree nodes and metadata
    private treeFilePath: string;

    // Cache for loaded leaf records
    private leafRecordsCache: Map<string, {
        records: ISortedIndexEntry<RecordT>[];
        dirty: boolean;
        lastAccessed: number;
    }> = new Map();
    
    // Map of all tree nodes
    private treeNodes: Map<string, IBTreeNode> = new Map();
    
    // Maximum number of pages to keep in cache
    private maxCachedPages: number = 10;
    
    private lastSaveTime: number | undefined = undefined;
    
    constructor(options: ISortIndexOptions, private readonly collection: IBsonCollection<RecordT>) {
        this.storage = options.storage;
        this.indexDirectory = `${options.baseDirectory}/sort_indexes/${options.collectionName}/${options.fieldName}_${options.direction}`;
        this.fieldName = options.fieldName;
        this.direction = options.direction;
        this.pageSize = options.pageSize || 1000;
        this.keySize = options.keySize || 100;
        this.type = options.type;
        this.treeFilePath = `${this.indexDirectory}/tree.dat`;
    }

    //
    // Lazily initializes the sort index.
    //
    async init(): Promise<void> {
        const loaded = await this.load();
        if (!loaded) {
            await this.build();
        }
    }

    //
    // Loads the sort index metadata and tree nodes from disk.
    // Returns false if the sort index is not built.
    //
    private async load(): Promise<boolean> {
        if (this.loaded) {
            return true; // Already loaded
        }
        
        const fileData = await retry(() => this.storage.read(this.treeFilePath));        
        if (fileData && fileData.length > 0) {
            // Skip the 32-byte checksum at the end
            const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);
            
            // Calculate checksum of the data
            const storedChecksum = fileData.subarray(fileData.length - 32);
            const calculatedChecksum = crypto.createHash('sha256').update(dataWithoutChecksum).digest();
            
            // Verify checksum
            if (!calculatedChecksum.equals(storedChecksum)) {
                console.error('Tree file checksum verification failed');
                return false;
            }
            
            // Read version number (first 4 bytes)
            const version = dataWithoutChecksum.readUInt32LE(0);
            
            if (version === 2) {
                // Binary format
                let offset = 4; // Skip version
                
                // Read metadata directly as binary data
                this.totalEntries = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                
                this.totalPages = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                
                // Read rootPageId length and data
                const rootPageIdLength = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                const rootPageIdBuffer = dataWithoutChecksum.subarray(offset, offset + rootPageIdLength);
                offset += rootPageIdLength;
                this.rootPageId = rootPageIdBuffer.toString('utf8') || this.rootPageId;
                
                // Read fieldName length and data
                const fieldNameLength = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                const fieldNameBuffer = dataWithoutChecksum.subarray(offset, offset + fieldNameLength);
                offset += fieldNameLength;
                
                // Read direction length and data
                const directionLength = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                const directionBuffer = dataWithoutChecksum.subarray(offset, offset + directionLength);
                offset += directionLength;
                
                // Read type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
                const typeValue = dataWithoutChecksum.readUInt8(offset);
                offset += 1;
                if (typeValue === 1) {
                    this.type = 'date';
                } else if (typeValue === 2) {
                    this.type = 'string';
                } else if (typeValue === 3) {
                    this.type = 'number';
                } else {
                    this.type = undefined;
                }
                
                // Read pageSize
                const pageSize = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                
                // Read lastUpdatedAt timestamp (8 bytes for Date)
                const lastUpdatedTimestamp = dataWithoutChecksum.readBigUInt64LE(offset);
                offset += 8;
                this.lastUpdatedAt = new Date(Number(lastUpdatedTimestamp));
                
                // Read number of nodes
                const nodeCount = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                
                // Read each node
                for (let i = 0; i < nodeCount; i++) {
                    // Read pageId length and data
                    const pageIdLength = dataWithoutChecksum.readUInt32LE(offset);
                    offset += 4;
                    const pageIdBuffer = dataWithoutChecksum.subarray(offset, offset + pageIdLength);
                    offset += pageIdLength;
                    const pageId = pageIdBuffer.toString('utf8');
                    
                    // Read node length and data
                    const nodeLength = dataWithoutChecksum.readUInt32LE(offset);
                    offset += 4;
                    const nodeBuffer = dataWithoutChecksum.subarray(offset, offset + nodeLength);
                    offset += nodeLength;
                    
                    // Deserialize the node
                    const { node } = this.deserializeNode(Buffer.from(nodeBuffer), 0);
                    this.treeNodes.set(pageId, node);
                }
                
                // Reconstruct parent-child relationships
                this.reconstructParentChildRelationships();
                
                this.loaded = true;
                this.dirty = false;
                return true;
            }
        }
        
        return false;
    }
    
    // Reconstruct parent-child relationships for all nodes
    private reconstructParentChildRelationships(): void {
        if (!this.rootPageId) return;
        
        // Start with the root node, which has no parent
        const rootNode = this.treeNodes.get(this.rootPageId);
        if (!rootNode) return;
        
        // Root node has no parent
        rootNode.parentId = undefined;
        
        // Recursively set parents for all children
        const setParentsForChildren = (nodeId: string): void => {
            const node = this.treeNodes.get(nodeId);
            if (!node || node.children.length === 0) return;
            
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
    private serializeNode(node: IBTreeNode, buffer: Buffer, offset: number): number {
        let currentOffset = offset;
        
        // Serialize keys as BSON and write length + data
        const keysBson = Buffer.from(BSON.serialize({ keys: node.keys }));
        buffer.writeUInt32LE(keysBson.length, currentOffset);
        currentOffset += 4;
        keysBson.copy(buffer, currentOffset);
        currentOffset += keysBson.length;
        
        // Write children count (4 bytes) and children data
        // Note: A node is a leaf if children.length === 0, no need for separate isLeaf flag
        buffer.writeUInt32LE(node.children.length, currentOffset);
        currentOffset += 4;
        
        for (const child of node.children) {
            const childBuffer = Buffer.from(child, 'utf8');
            buffer.writeUInt32LE(childBuffer.length, currentOffset);
            currentOffset += 4;
            childBuffer.copy(buffer, currentOffset);
            currentOffset += childBuffer.length;
        }
        
        // Write nextLeaf if it exists
        if (node.nextLeaf) {
            const nextLeafBuffer = Buffer.from(node.nextLeaf, 'utf8');
            buffer.writeUInt32LE(nextLeafBuffer.length, currentOffset);
            currentOffset += 4;
            nextLeafBuffer.copy(buffer, currentOffset);
            currentOffset += nextLeafBuffer.length;
        } else {
            // Write 0 length for no nextLeaf
            buffer.writeUInt32LE(0, currentOffset);
            currentOffset += 4;
        }
        
        // Write previousLeaf if it exists
        if (node.previousLeaf) {
            const previousLeafBuffer = Buffer.from(node.previousLeaf, 'utf8');
            buffer.writeUInt32LE(previousLeafBuffer.length, currentOffset);
            currentOffset += 4;
            previousLeafBuffer.copy(buffer, currentOffset);
            currentOffset += previousLeafBuffer.length;
        } else {
            // Write 0 length for no previousLeaf
            buffer.writeUInt32LE(0, currentOffset);
            currentOffset += 4;
        }
               
        // parentId is deliberately not serialized - it will be reconstructed during load
        
        return currentOffset;
    }
    
    // Deserialize a single node from a buffer
    private deserializeNode(buffer: Buffer, offset: number): { node: IBTreeNode, nextOffset: number } {
        let currentOffset = offset;
        
        // Read keys length and data
        const keysLength = buffer.readUInt32LE(currentOffset);
        currentOffset += 4;
        const keysBson = buffer.subarray(currentOffset, currentOffset + keysLength);
        currentOffset += keysLength;
        const keysData = BSON.deserialize(keysBson);
        const keys = keysData.keys || [];
        
        // Read children count and data
        const childrenCount = buffer.readUInt32LE(currentOffset);
        currentOffset += 4;
        const children: string[] = [];
        
        for (let i = 0; i < childrenCount; i++) {
            const childLength = buffer.readUInt32LE(currentOffset);
            currentOffset += 4;
            const childBuffer = buffer.subarray(currentOffset, currentOffset + childLength);
            currentOffset += childLength;
            children.push(childBuffer.toString('utf8'));
        }
        
        // Read nextLeaf
        const nextLeafLength = buffer.readUInt32LE(currentOffset);
        currentOffset += 4;
        let nextLeaf: string | undefined = undefined;
        
        if (nextLeafLength > 0) {
            const nextLeafBuffer = buffer.subarray(currentOffset, currentOffset + nextLeafLength);
            currentOffset += nextLeafLength;
            nextLeaf = nextLeafBuffer.toString('utf8');
        }
        
        // Read previousLeaf
        const previousLeafLength = buffer.readUInt32LE(currentOffset);
        currentOffset += 4;
        let previousLeaf: string | undefined = undefined;
        
        if (previousLeafLength > 0) {
            const previousLeafBuffer = buffer.subarray(currentOffset, currentOffset + previousLeafLength);
            currentOffset += previousLeafLength;
            previousLeaf = previousLeafBuffer.toString('utf8');
        }
        
        // Read numRecords if there is data left
        let numRecords = 0;
        if (currentOffset < buffer.length) {
            // Check if there's data for numRecords (for backward compatibility)
            numRecords = buffer.readUInt32LE(currentOffset);
            currentOffset += 4;
        }
        
        // parentId is not present in the serialized format anymore
        // It will be reconstructed after loading all nodes
        
        const node: IBTreeNode = {
            keys,
            children,
            nextLeaf,
            previousLeaf,
            // parentId is initially undefined
            // A node is a leaf if children.length === 0
        };
        
        return { node, nextOffset: currentOffset };
    }

    // Save the tree nodes and metadata to a single file
    async saveTree(): Promise<void> {
        if (!this.rootPageId) {
            throw new Error('Root page ID is not set. Cannot save tree.');
        }

        // Calculate total size needed for the buffer
        const rootPageIdBuffer = Buffer.from(this.rootPageId, 'utf8');
        const fieldNameBuffer = Buffer.from(this.fieldName, 'utf8');
        const directionBuffer = Buffer.from(this.direction, 'utf8');
        
        // Calculate size for all nodes
        let totalNodesSize = 0;
        
        // First pass: calculate the total size needed
        for (const [pageId, node] of this.treeNodes.entries()) {
            const pageIdBuffer = Buffer.from(pageId, 'utf8');
            
            // Estimate node size without actually serializing
            let estimatedSize = 1; // isLeaf flag
            
            // Keys BSON size estimate
            const keysBson = Buffer.from(BSON.serialize({ keys: node.keys }));
            estimatedSize += 4 + keysBson.length; // keys length + data
            
            // Children size estimate
            estimatedSize += 4; // children count
            for (const child of node.children) {
                estimatedSize += 4 + Buffer.from(child, 'utf8').length; // child length + data
            }
            
            // nextLeaf and previousLeaf size estimate
            estimatedSize += 4; // nextLeaf length
            if (node.nextLeaf) {
                estimatedSize += Buffer.from(node.nextLeaf, 'utf8').length;
            }
            
            estimatedSize += 4; // previousLeaf length
            if (node.previousLeaf) {
                estimatedSize += Buffer.from(node.previousLeaf, 'utf8').length;
            }
            
            estimatedSize += 4; // numRecords
            
            totalNodesSize += 4 + pageIdBuffer.length + 4 + estimatedSize; // pageId length + pageId + node length + node data
        }
        
        // Calculate total buffer size
        const totalSize = 
            4 + // version
            4 + // totalEntries
            4 + // totalPages  
            4 + rootPageIdBuffer.length + // rootPageId length + data
            4 + fieldNameBuffer.length + // fieldName length + data
            4 + directionBuffer.length + // direction length + data
            1 + // type (single byte: 0 for no type, 1 for date)
            4 + // pageSize
            8 + // lastUpdatedAt timestamp
            4 + // node count
            totalNodesSize; // all nodes
        
        // Allocate single buffer
        const buffer = Buffer.alloc(totalSize);
        let offset = 0;
        
        // Write version number (4 bytes) - version 2 for new binary format
        buffer.writeUInt32LE(2, offset);
        offset += 4;
        
        // Write metadata directly as binary data
        buffer.writeUInt32LE(this.totalEntries, offset);
        offset += 4;
        
        buffer.writeUInt32LE(this.totalPages, offset);
        offset += 4;
        
        // Write rootPageId length and data
        buffer.writeUInt32LE(rootPageIdBuffer.length, offset);
        offset += 4;
        rootPageIdBuffer.copy(buffer, offset);
        offset += rootPageIdBuffer.length;
        
        // Write fieldName length and data
        buffer.writeUInt32LE(fieldNameBuffer.length, offset);
        offset += 4;
        fieldNameBuffer.copy(buffer, offset);
        offset += fieldNameBuffer.length;
        
        // Write direction length and data
        buffer.writeUInt32LE(directionBuffer.length, offset);
        offset += 4;
        directionBuffer.copy(buffer, offset);
        offset += directionBuffer.length;
        
        // Write type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
        let typeValue = 0;
        if (this.type === 'date') {
            typeValue = 1;
        } else if (this.type === 'string') {
            typeValue = 2;
        } else if (this.type === 'number') {
            typeValue = 3;
        }
        buffer.writeUInt8(typeValue, offset);
        offset += 1;
        
        // Write pageSize
        buffer.writeUInt32LE(this.pageSize, offset);
        offset += 4;
        
        // Write lastUpdatedAt timestamp (8 bytes for Date)
        const timestamp = this.lastUpdatedAt ? BigInt(this.lastUpdatedAt.getTime()) : BigInt(0);
        buffer.writeBigUInt64LE(timestamp, offset);
        offset += 8;
        
        // Write number of nodes
        buffer.writeUInt32LE(this.treeNodes.size, offset);
        offset += 4;
        
        // Second pass: write the nodes
        for (const [pageId, node] of this.treeNodes.entries()) {
            const pageIdBuffer = Buffer.from(pageId, 'utf8');
            
            // Write pageId length and data
            buffer.writeUInt32LE(pageIdBuffer.length, offset);
            offset += 4;
            pageIdBuffer.copy(buffer, offset);
            offset += pageIdBuffer.length;
            
            // Reserve space for node length (will fill in after serialization)
            const nodeLengthPosition = offset;
            offset += 4;
            
            // Serialize the node directly into the buffer
            const endOffset = this.serializeNode(node, buffer, offset);
            
            // Calculate and write actual node length
            const nodeLength = endOffset - offset;
            buffer.writeUInt32LE(nodeLength, nodeLengthPosition);
            
            // Update offset to the end of the serialized node
            offset = endOffset;
        }
        
        // Calculate checksum
        const checksum = crypto.createHash('sha256').update(buffer).digest();
        
        // Combine data and checksum
        const dataWithChecksum = Buffer.concat([buffer, checksum]);
        
        // Write to storage        
        await retry(() => this.storage.write(this.treeFilePath, undefined, dataWithChecksum));
    }

    //
    // Builds the sort index by directly inserting records from the collection.
    //
    async build(): Promise<void> {
        if (this.loaded) {
            return;
        }
       
        // Create an empty root leaf node to start with (empty children array means it's a leaf)
        const emptyRoot: IBTreeNode = {
            keys: [],
            children: [],
            nextLeaf: undefined,
            previousLeaf: undefined,
            parentId: undefined,
        };

        this.rootPageId = makeId(); // Generate a new UUID for the root page ID.
        
        // Store in the tree nodes map
        this.treeNodes.set(this.rootPageId, emptyRoot);
        
        // Create empty leaf records array
        const emptyLeafRecords: ISortedIndexEntry<RecordT>[] = [];
        await this.saveLeafRecords(this.rootPageId, emptyLeafRecords);
        
        this.totalEntries = 0;
        this.totalPages = 1; // Start with a single leaf page
        
        // Track whether we've added any records
        let recordsAdded = 0;

        let startTime = Date.now();
        
        // Iterate through all records and add them directly to the B-tree
        for await (const record of this.collection.iterateRecords()) {
            const value = record[this.fieldName];
            if (value !== undefined) {
                // Add each record directly to the index
                await this.addRecord(record);
                recordsAdded++;
            }
        }
        
        // Save tree nodes and metadata to the single file
        await this.saveTree();
               
        // Save metadata
        await this.markDirty();
        
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
                    throw new Error(`Type mismatch in compareValues: first value is Date, second value is ${typeof b}`);
                }
            }
            else if (inferredType === 'number') {
                if (typeof b !== 'number') {
                    throw new Error(`Type mismatch in compareValues: first value is number, second value is ${typeof b}`);
                }
            }
            else if (inferredType === 'string') {
                if (typeof b !== 'string') {
                    throw new Error(`Type mismatch in compareValues: first value is string, second value is ${typeof b}`);
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
    
    // Save leaf records to separate file
    private async saveLeafRecords(pageId: string, records: ISortedIndexEntry<RecordT>[]): Promise<void> {
        const filePath = `${this.indexDirectory}/${pageId}`;
        
        // First pass: calculate total buffer size needed
        let totalSize = 4 + 4; // version (4 bytes) + record count (4 bytes)
        
        for (const entry of records) {
            const idSize = Buffer.byteLength(entry.recordId, 'utf8');
            const valueBsonSize = BSON.calculateObjectSize({ value: entry.value });
            const recordBsonSize = BSON.calculateObjectSize(entry.record);
            
            // Add to total: 4 bytes for ID length + ID data + 4 bytes for value length + value data + 4 bytes for record length + record data
            totalSize += 4 + idSize + 4 + valueBsonSize + 4 + recordBsonSize;
        }
        
        // Allocate buffer
        const buffer = Buffer.alloc(totalSize);
        let offset = 0;
        
        // Write version number (4 bytes) - version 1 for new format
        buffer.writeUInt32LE(1, offset);
        offset += 4;
        
        // Write record count
        buffer.writeUInt32LE(records.length, offset);
        offset += 4;
        
        // Second pass: write each record
        for (const entry of records) {
            // Write record ID
            const idBuffer = Buffer.from(entry.recordId, 'utf8');
            buffer.writeUInt32LE(idBuffer.length, offset);
            offset += 4;
            idBuffer.copy(buffer, offset);
            offset += idBuffer.length;
            
            // Write value as BSON
            const valueBson = Buffer.from(BSON.serialize({ value: entry.value }));
            buffer.writeUInt32LE(valueBson.length, offset);
            offset += 4;
            valueBson.copy(buffer, offset);
            offset += valueBson.length;
            
            // Write record as BSON
            const recordBson = Buffer.from(BSON.serialize(entry.record));
            buffer.writeUInt32LE(recordBson.length, offset);
            offset += 4;
            recordBson.copy(buffer, offset);
            offset += recordBson.length;
        }
        
        // Calculate checksum
        const checksum = crypto.createHash('sha256').update(buffer).digest();
        
        // Combine data and checksum
        const dataWithChecksum = Buffer.concat([buffer, checksum]);

        // console.log(`Saving leaf records for page ${pageId} with ${records.length}`);
        
        // Write to storage
        await retry(() =>  this.storage.write(filePath, undefined, dataWithChecksum));
    }
    
    // Load leaf records from file
    private async loadLeafRecords(pageId: string): Promise<ISortedIndexEntry<RecordT>[] | undefined> {
        const filePath = `${this.indexDirectory}/${pageId}`;
        
        const fileData = await retry(() => this.storage.read(filePath));
        
        if (fileData && fileData.length > 0) {
            // Skip the 32-byte checksum at the end
            const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);
            
            // Calculate checksum of the data
            const storedChecksum = fileData.subarray(fileData.length - 32);
            const calculatedChecksum = crypto.createHash('sha256').update(dataWithoutChecksum).digest();
            
            // Verify checksum
            if (!calculatedChecksum.equals(storedChecksum)) {
                console.error(`Leaf records file checksum verification failed: ${filePath}`);
                return undefined;
            }
            
            // Check if this is the new format by reading the first 4 bytes as version
            if (dataWithoutChecksum.length >= 4 && dataWithoutChecksum.readUInt32LE(0) === 1) {
                // New buffer format
                let offset = 4; // Skip version (4 bytes)
                
                // Read record count
                const recordCount = dataWithoutChecksum.readUInt32LE(offset);
                offset += 4;
                
                const records: ISortedIndexEntry<RecordT>[] = [];
                
                // Read each record
                for (let i = 0; i < recordCount; i++) {
                    // Read record ID
                    const idLength = dataWithoutChecksum.readUInt32LE(offset);
                    offset += 4;
                    const recordId = dataWithoutChecksum.subarray(offset, offset + idLength).toString('utf8');
                    offset += idLength;
                    
                    // Read value BSON
                    const valueLength = dataWithoutChecksum.readUInt32LE(offset);
                    offset += 4;
                    const valueBson = dataWithoutChecksum.subarray(offset, offset + valueLength);
                    offset += valueLength;
                    const valueObj = BSON.deserialize(valueBson);
                    const value = valueObj.value;
                    
                    // Read record BSON
                    const recordLength = dataWithoutChecksum.readUInt32LE(offset);
                    offset += 4;
                    const recordBson = dataWithoutChecksum.subarray(offset, offset + recordLength);
                    offset += recordLength;
                    const record = BSON.deserialize(recordBson) as RecordT;
                    
                    records.push({
                        recordId,
                        value,
                        record
                    });
                }
                
                // Update numRecords in the node
                const node = this.getNode(pageId);
                if (node && node.children.length === 0) {
                    this.markNodeDirty(pageId, node);
                }
                
                return records;
            } else {
                // Old BSON array format (backward compatibility)
                const leafRecordsObj = BSON.deserialize(dataWithoutChecksum);
                const records = leafRecordsObj.records as ISortedIndexEntry<RecordT>[];
                
                // Update numRecords in the node
                const node = this.getNode(pageId);
                if (node && node.children.length === 0) {
                    this.markNodeDirty(pageId, node);
                }
                
                return records;
            }
        }
        
        return undefined;
    }
    
    // Get a node from cache or map
    private getNode(pageId: string): IBTreeNode | undefined {       
        return this.treeNodes.get(pageId);
    }
    
    // Get leaf records from cache or load from file
    private async getLeafRecords(pageId: string): Promise<ISortedIndexEntry<RecordT>[] | undefined> {
        // Check if records are in cache
        const cachedRecords = this.leafRecordsCache.get(pageId);
        if (cachedRecords) {
            // Update last accessed time
            cachedRecords.lastAccessed = Date.now();
            return cachedRecords.records;
        }
        
        // Load from storage if not in cache
        const records = await this.loadLeafRecords(pageId);
        
        // If loaded successfully, add to cache
        if (records) {
            this.leafRecordsCache.set(pageId, {
                records,
                dirty: false,
                lastAccessed: Date.now(),
            });
            
            // Evict oldest records if cache is too large
            await this.evictOldestLeafRecords();
        }
        
        return records;
    }
    
    // Mark a node as dirty and schedule a save
    private async markNodeDirty(pageId: string, node: IBTreeNode): Promise<void> {
        this.dirty = true;

        // Store in tree nodes map
        this.treeNodes.set(pageId, node);
                
        // Schedule a save
        await this.scheduleSave(`updated node ${pageId}`);
    }
    
    // Mark leaf records as dirty and schedule a save
    private async markLeafRecordsDirty(pageId: string, records: ISortedIndexEntry<RecordT>[], reason: string): Promise<void> {
        const cachedRecords = this.leafRecordsCache.get(pageId);
        // console.log(`Marking leaf records for page ${pageId} as dirty because ${reason}`);
        if (cachedRecords) {
            // Update existing cache entry
            cachedRecords.records = records;
            cachedRecords.dirty = true;
            cachedRecords.lastAccessed = Date.now();
        } else {
            // Add to cache if not already there
            this.leafRecordsCache.set(pageId, {
                records,
                dirty: true,
                lastAccessed: Date.now(),
            });
        }
        
        // Schedule a save
        await this.scheduleSave(`updated leaf records ${pageId}`);
    }
        
    // Evict oldest leaf records that are not dirty from cache
    private async evictOldestLeafRecords(): Promise<void> {

        //
        // First stage of eviction: remove oldest non-dirty records.
        //

        if (this.leafRecordsCache.size <= this.maxCachedPages) {
            return; // No need to evict
        }
        
        let numRecordsToEvict = this.leafRecordsCache.size - this.maxCachedPages;
        
        // Sort non-dirty records by last accessed time
        const records = Array.from(this.leafRecordsCache.entries())
            .filter(([_, rec]) => !rec.dirty)
            .sort(([_a, recA], [_b, recB]) => recA.lastAccessed - recB.lastAccessed);
        
        // Evict oldest records
        for (let i = 0; i < numRecordsToEvict && i < records.length; i++) {
            // console.log(`Evicting non-dirty leaf records for page ${records[i][0]}`);
            this.leafRecordsCache.delete(records[i][0]);
        }

        //
        // Second stage of eviction: if we still have too many cached pages,
        // We will save and evict the oldest dirty records as well.
        //

        if (this.leafRecordsCache.size <= this.maxCachedPages) {
            return; // No need to evict
        }
        
        numRecordsToEvict = this.leafRecordsCache.size - this.maxCachedPages;

        const dirtyRecords = Array.from(this.leafRecordsCache.entries())
            .filter(([_, rec]) => rec.dirty)
            .sort(([_a, recA], [_b, recB]) => recA.lastAccessed - recB.lastAccessed);

        // Evict oldest dirty records
        for (let i = 0; i < numRecordsToEvict && i < dirtyRecords.length; i++) {
            const [pageId, cachedRecords] = dirtyRecords[i];

            // console.log(`Saving and evicting dirty leaf records for page ${pageId}`);
            
            // Save dirty records before eviction.
            await this.saveLeafRecords(pageId, cachedRecords.records);

            // Evict from cache.
            this.leafRecordsCache.delete(pageId);            
        }
    }
    
    // Schedule saving of all dirty nodes
    private async scheduleSave(reason: string): Promise<void> {        
        if (this.lastSaveTime === undefined) {
            this.lastSaveTime = Date.now();
        } 
        else {
            const timeNow = Date.now();
            const timeSinceLastSaveMs = timeNow - this.lastSaveTime;
            
            if (timeSinceLastSaveMs > maxSaveDelayMs) {
                // Too much time elapsed, save immediately
                await this.saveDirtyNodes();
                return;
            }
        }
    }   
   
    // Save all dirty nodes and metadata
    private async saveDirtyNodes(): Promise<void> {
        if (this.saving) {            
            console.warn(`Save already in progress, skipping save.`);
            return; // Avoid concurrent saves.
        }

        this.saving = true;

        try {
            // Save dirty metadata and tree nodes if exists
            if (this.dirty) {
                await this.saveTree();
            }
                    
            // Save all dirty leaf records
            const dirtyLeafRecords = Array.from(this.leafRecordsCache.entries())
                .filter(([_, rec]) => rec.dirty);            
            if (dirtyLeafRecords.length > 0) {
                // for (const [pageId, cachedRecords] of dirtyLeafRecords) {
                //     console.log(`  ${pageId}`);
                // }
    
                for (const [pageId, cachedRecords] of dirtyLeafRecords) {
                    await this.saveLeafRecords(pageId, cachedRecords.records);
                    cachedRecords.dirty = false; // Mark as clean after saving

                }
            }
            
            this.lastSaveTime = Date.now();
            
            // Now that we've saved, we can evict oldest nodes and records
            await this.evictOldestLeafRecords();
        }
        finally {
            this.saving = false;
        }
    }
    
    //
    // Marks the tree as dirty and schedules a save.
    //
    private async markDirty(): Promise<void> {
        this.lastUpdatedAt = new Date();
        this.dirty = true;
        
        // Schedule save
        await this.scheduleSave('updated metadata');
    }
    
    
    //
    // Get a page of records from the collection using the sort index.
    //
    async getPage(pageId?: string): Promise<ISortResult<RecordT>> {
        await this.init();
        
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
        const leafRecords = await this.getLeafRecords(pageId);
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
        
        // Get the records from this page
        const pageRecords = leafRecords.map(entry => entry.record);
        
        // Get next page ID from the node's nextLeaf property
        const nextPageId = node.nextLeaf;
        
        // Get previous page ID directly from the node's previousLeaf property
        const previousPageId = node.previousLeaf;
        
        // Return the result with pagination info
        return {
            records: pageRecords,
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
        this.leafRecordsCache.clear();
        this.treeNodes.clear();
    }
    
    /**
     * Updates a record in the index without rebuilding the entire index
     * If the indexed field value has changed, the record will be removed and added again
     */
    async updateRecord(record: RecordT, oldRecord: RecordT | undefined): Promise<void> {
        await this.init();

        const recordId = record._id;
        const oldValue = oldRecord && oldRecord[this.fieldName];
        
        // First remove old record completely
        let recordRemoved = false;
        if (oldValue !== undefined) {
            // First try to quickly find the specific leaf
            const leafId = this.findLeafForValue(oldValue);
            if (leafId) {
                const leafNode = this.getNode(leafId);
                const leafRecords = await this.getLeafRecords(leafId);
                
                if (leafNode && leafNode.children.length === 0 && leafRecords) {
                    // Find the entry with matching ID
                    const entryIndex = leafRecords.findIndex(
                        entry => entry.recordId === recordId
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
                                    await this.markNodeDirty(prevLeafId, prevLeafNode);
                                }
                            }
                            
                            // Update the previousLeaf pointer of the next node
                            if (leafNode.nextLeaf) {
                                const nextLeafNode = this.getNode(leafNode.nextLeaf);
                                if (nextLeafNode && nextLeafNode.children.length === 0) {
                                    nextLeafNode.previousLeaf = prevLeafId;
                                    await this.markNodeDirty(leafNode.nextLeaf, nextLeafNode);
                                }
                            }
                            
                            // Remove leaf records file
                            const leafRecordsPath = `${this.indexDirectory}/${leafId}`;
                            await this.storage.deleteFile(leafRecordsPath);
                            
                            // Remove the node from the treeNodes map
                            this.treeNodes.delete(leafId);
                            
                            // Decrement total pages since we're effectively removing this page
                            this.totalPages--;
                        } else {
                            // Update leaf records
                            await this.markLeafRecordsDirty(leafId, leafRecords, `removed index ${entryIndex}`);
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
                            const leafRecords = await this.getLeafRecords(currentId);
                            if (leafRecords) {
                                // Find the entry with matching ID
                                const entryIndex = leafRecords.findIndex(
                                    entry => entry.recordId === recordId
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
                                                await this.markNodeDirty(prevNodeId, prevNode);
                                            }
                                        }
                                        
                                        // Update the previousLeaf pointer of the next node
                                        if (currentNode.nextLeaf) {
                                            const nextNode = this.getNode(currentNode.nextLeaf);
                                            if (nextNode && nextNode.children.length === 0) {
                                                nextNode.previousLeaf = prevNodeId;
                                                await this.markNodeDirty(currentNode.nextLeaf, nextNode);
                                            }
                                        }
                                        
                                        // Remove leaf records file
                                        const leafRecordsPath = `${this.indexDirectory}/${currentId}`;
                                        await this.storage.deleteFile(leafRecordsPath);
                                        
                                        // Remove the node from the treeNodes map
                                        this.treeNodes.delete(currentId);
                                        
                                        // Decrement total pages since we're effectively removing this page
                                        this.totalPages--;
                                    } else {
                                        // Update leaf records
                                        await this.markLeafRecordsDirty(currentId, leafRecords, `removed index ${entryIndex}`);
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
    async deleteRecord(recordId: string, value: any): Promise<void> {
        await this.init();
        
        // Value is now required
        if (value === undefined) {
            throw new Error(`Value for field '${this.fieldName}' is required for deleting records from sort index`);
        }
        
        let recordDeleted = false;
        
        // First try to find the record in the expected leaf
        const leafId = this.findLeafForValue(value);
        if (leafId) {
            const leafNode = this.getNode(leafId);
            const leafRecords = await this.getLeafRecords(leafId);
            
            if (leafNode && leafNode.children.length === 0 && leafRecords) {
                // Find the entry with matching ID
                const entryIndex = leafRecords.findIndex(
                    entry => entry.recordId === recordId
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
                                await this.markNodeDirty(prevLeafId, prevLeafNode);
                            }
                        }
                        
                        // Update the previousLeaf pointer of the next node
                        if (leafNode.nextLeaf) {
                            const nextLeafNode = this.getNode(leafNode.nextLeaf);
                            if (nextLeafNode && nextLeafNode.children.length === 0) {
                                nextLeafNode.previousLeaf = prevLeafId;
                                await this.markNodeDirty(leafNode.nextLeaf, nextLeafNode);
                            }
                        }
                        
                        // Remove leaf records file
                        const leafRecordsPath = `${this.indexDirectory}/${leafId}`;
                        await this.storage.deleteFile(leafRecordsPath);
                        
                        // Remove the node from the treeNodes map
                        this.treeNodes.delete(leafId);
                        
                        // Decrement total pages since we're effectively removing this page
                        this.totalPages--;
                    } else {
                        // Update the leaf records
                        await this.markLeafRecordsDirty(leafId, leafRecords, `removed index ${entryIndex}`);
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
                        const leafRecords = await this.getLeafRecords(currentId);
                        if (leafRecords) {
                            // Find the entry with matching ID
                            const entryIndex = leafRecords.findIndex(
                                entry => entry.recordId === recordId
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
                                            await this.markNodeDirty(prevNodeId, prevNode);
                                        }
                                    }
                                    
                                    // Update the previousLeaf pointer of the next node
                                    if (currentNode.nextLeaf) {
                                        const nextNode = this.getNode(currentNode.nextLeaf);
                                        if (nextNode && nextNode.children.length === 0) {
                                            nextNode.previousLeaf = prevNodeId;
                                            await this.markNodeDirty(currentNode.nextLeaf, nextNode);
                                        }
                                    }
                                    
                                    // Remove leaf records file
                                    const leafRecordsPath = `${this.indexDirectory}/${currentId}`;
                                    await this.storage.deleteFile(leafRecordsPath);
                                    
                                    // Remove the node from the treeNodes map
                                    this.treeNodes.delete(currentId);
                                    
                                    // Decrement total pages since we're effectively removing this page
                                    this.totalPages--;
                                } else {
                                    // Update the leaf records
                                    await this.markLeafRecordsDirty(currentId, leafRecords, `removed index ${entryIndex}`);
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
            await this.markDirty();
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
        if (!node || !node.parentId) return;
               
        const parentNode = this.getNode(node.parentId);
        if (!parentNode) return;
        
        // Find the index of the key that references this node
        const childIndex = parentNode.children.indexOf(nodeId);
        
        // If this isn't the leftmost child (i > 0), it has a key in the parent
        if (childIndex > 0 && this.compareValues(parentNode.keys[childIndex - 1], oldKey) === 0) {
            parentNode.keys[childIndex - 1] = newKey;
            await this.markNodeDirty(node.parentId, parentNode);
        }
        
        // Recursively update parent nodes if needed
        await this.updateKeyInParents(node.parentId, oldKey, newKey);
    }
    
    /**
     * Adds a new record to the index without rebuilding the entire index
     */
    async addRecord(record: RecordT): Promise<void> {       
        const recordId = record._id;
        const value = record[this.fieldName];
        
        // If the field doesn't exist in the record, don't add it to the index
        if (value === undefined) {
            return;
        }
        
        // Create the new entry
        const newEntry: ISortedIndexEntry<RecordT> = {
            recordId,
            value,
            record
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
        let leafRecords = await this.getLeafRecords(leafId) || [];
        
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
        if (leafRecords.length > this.pageSize * 1.2) {
            await this.splitLeafNode(leafId, leafNode, leafRecords);
        } 
        else {
            // Just update the leaf records
            await this.markLeafRecordsDirty(leafId, leafRecords, `added index at ${insertIndex}`);
        }
        
        // Increment total entries
        this.totalEntries++;
        
        // Update metadata
        await this.markDirty();

        // Evict oldest records if cache is too large
        await this.evictOldestLeafRecords();
    }
    
    /**
     * Splits a leaf node when it gets too large
     */
    private async splitLeafNode(nodeId: string, node: IBTreeNode, records: ISortedIndexEntry<RecordT>[]): Promise<void> {
        if (node.children.length > 0) {
            return;
        }
        
        // Ensure entries are properly sorted first
        records.sort((a, b) => this.compareValues(a.value, b.value));
        
        // Split point
        const splitIndex = Math.floor(records.length / 2);
        
        // Create new leaf node with the second half
        const newEntries = records.splice(splitIndex);
        const newNodeId = makeId();

        
        const newNode: IBTreeNode = {
            // Node is a leaf (children array is empty)
            keys: [],
            children: [],
            nextLeaf: node.nextLeaf,
            previousLeaf: nodeId,
            parentId: node.parentId, // Copy parent from original node
        };
        
        // Update pointers in the original node
        node.nextLeaf = newNodeId;
        
        // Update the previousLeaf pointer of the node that comes after the new node
        if (newNode.nextLeaf) {
            const nextNode = this.getNode(newNode.nextLeaf);
            if (nextNode && nextNode.children.length === 0) {
                nextNode.previousLeaf = newNodeId;
                await this.markNodeDirty(newNode.nextLeaf, nextNode);
            }
        }
        
        // Create or update parent node to maintain the B-tree structure
        if (nodeId === this.rootPageId && node.children.length === 0) {
            // If we're splitting the root, we need to create a new root
            const newRootId = makeId();
            const newRoot: IBTreeNode = {
                // Internal node (has children)
                keys: [newEntries[0].value],
                children: [nodeId, newNodeId],
                parentId: undefined,
            };
            
            // Save the new root
            await this.markNodeDirty(newRootId, newRoot);
            
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
                    
                    // Save the updated parent node
                    await this.markNodeDirty(parentId, parentNode);
                    
                    // If the parent node is now too large, we need to split it too
                    if (parentNode.keys.length > this.keySize) {
                        await this.splitInternalNode(parentId, parentNode);
                    }
                }
            }
        }
        
        // Save both nodes
        await this.markNodeDirty(nodeId, node);
        await this.markNodeDirty(newNodeId, newNode);
        
        // Save leaf records for both nodes
        await this.markLeafRecordsDirty(nodeId, records, `split leaf at ${splitIndex}`);
        await this.markLeafRecordsDirty(newNodeId, newEntries, `split leaf at ${splitIndex}`);
        
        // Increment total pages since we created a new leaf page
        this.totalPages++;
        
        // Update metadata with the new root page ID
        await this.markDirty();
    }
    
    // Find records by exact value using binary search on the sorted index
    async findByValue(value: any): Promise<RecordT[]> {
        await this.init();
        
        const matchingEntries: ISortedIndexEntry<RecordT>[] = [];
        
        // First try to find the specific leaf that should contain this value
        const leafId = this.findLeafForValue(value);
        if (!leafId) {
            // No leaf found that might contain this value
            return [];
        }
        
        // Process the initial leaf node
        const leafNode = this.getNode(leafId);
        const leafRecords = await this.getLeafRecords(leafId);
        
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
                    
                    const nextRecords = await this.getLeafRecords(nextId);
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
                    
                    const prevRecords = await this.getLeafRecords(prevId);
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
                
                const currentRecords = await this.getLeafRecords(currentId);
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
        return matchingEntries.map(entry => entry.record);
    }
    
    // Find records by range query using optimized leaf traversal.
    async findByRange(options: {
        min?: any;
        max?: any;
        minInclusive?: boolean;
        maxInclusive?: boolean;
    }): Promise<RecordT[]> {
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
        
        await this.init();
        
        const matchingRecords: RecordT[] = [];
        
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
            
            const leafRecords = await this.getLeafRecords(currentId);
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
                matchingRecords.push(entry.record);
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
        matchingRecords.sort((a, b) => this.compareValues(a[this.fieldName], b[this.fieldName]));
        
        return matchingRecords;
    }

    /**
     * Splits an internal node when it gets too large
     */
    private async splitInternalNode(nodeId: string, node: IBTreeNode): Promise<void> {
        if (node.children.length === 0) {
            return; // Only process internal nodes
        }
        
        // Find the middle index
        const middleIndex = Math.floor(node.keys.length / 2);
        
        // The middle key will be promoted to the parent
        const middleKey = node.keys[middleIndex];
        
        // Create a new internal node for the right half
        const newNodeId = makeId();
        const newNode: IBTreeNode = {
            // Internal node (has children)
            keys: node.keys.splice(middleIndex + 1), // Take keys after the middle
            children: node.children.splice(middleIndex + 1), // Take children after the middle
            parentId: node.parentId,
        };
        
        // Remove the middle key from the original node (it goes up to the parent)
        node.keys.splice(middleIndex, 1);
        
        // Update parent references for all children of the new node
        for (const childId of newNode.children) {
            const childNode = this.getNode(childId);
            if (childNode) {
                childNode.parentId = newNodeId;
                await this.markNodeDirty(childId, childNode);
            }
        }
        
        // If this is the root node, create a new root
        if (nodeId === this.rootPageId) {
            const newRootId = makeId();
            const newRoot: IBTreeNode = {
                // Internal node (has children)
                keys: [middleKey],
                children: [nodeId, newNodeId],
                parentId: undefined,
            };
            
            // Update parent references
            node.parentId = newRootId;
            newNode.parentId = newRootId;
            
            // Save the new root
            await this.markNodeDirty(newRootId, newRoot);
            
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
                    
                    // Save the updated parent
                    await this.markNodeDirty(parentId, parentNode);
                    
                    // Check if the parent needs to be split
                    if (parentNode.keys.length > this.keySize) {
                        await this.splitInternalNode(parentId, parentNode);
                    }
                }
            }
        }
        
        // Save both nodes
        await this.markNodeDirty(nodeId, node);
        await this.markNodeDirty(newNodeId, newNode);
        
        // Note: Not incrementing totalPages here since internal nodes
        // don't count toward the user-facing page count
    }

    /**
     * Saves all dirty nodes and metadata, then clears the cache
     * Should be called when shutting down the database
     */
    async shutdown(): Promise<void> {        
        // Save all dirty nodes and metadata
        await this.saveDirtyNodes();
        
        // Save all tree nodes and metadata
        await this.saveTree();
        
        // Clear the cache
        this.leafRecordsCache.clear();
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
            if (!node) return;
            
            const indent = "  ".repeat(level);
            const nodeType = node.children.length === 0 ? "LEAF" : "INTERNAL";
            
            lines.push(`${indent}[${nodeId}] ${nodeType} NODE`);
            
            if (node.keys.length > 0) {
                lines.push(`${indent} Keys: ${node.keys.join(', ')}`);
            }
            
            if (node.children.length === 0) {
                const records = await this.getLeafRecords(nodeId);
                if (records && records.length > 0) {
                    lines.push(`${indent} Records: ${records.length}`);
                    // Show first few records for preview
                    const preview = records.slice(0, 3).map(r => `${r.value}`).join(', ');
                    if (records.length > 3) {
                        lines.push(`${indent} Values: ${preview}, ...`);
                    } else {
                        lines.push(`${indent} Values: ${preview}`);
                    }
                    
                    if (node.nextLeaf) {
                        lines.push(`${indent} Next leaf: ${node.nextLeaf}`);
                    }
                    if (node.previousLeaf) {
                        lines.push(`${indent} Previous leaf: ${node.previousLeaf}`);
                    }
                }
            } else {
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
            await this.init();
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
        
        // Traverse all nodes
        for (const [nodeId, node] of this.treeNodes.entries()) {
            const isLeaf = node.children.length === 0;
            let keyCount = node.keys.length;
            
            // For leaf nodes, also count the records
            if (isLeaf) {
                const records = await this.getLeafRecords(nodeId);
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