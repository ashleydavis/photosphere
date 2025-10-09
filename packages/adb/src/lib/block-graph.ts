import { v4 as uuid } from 'uuid';
import { IStorage } from 'storage';
import { DatabaseUpdate } from './database-update';
import { BSON } from 'bson';

//
// Binary Block Format:
// [Version: 4 bytes LE][Block ID: 16 bytes][Prev Count: 4 bytes LE][Prev IDs: N*16 bytes][Data Length: 4 bytes LE][Data: BSON]
//
// All multi-byte integers are stored in Little Endian format.
// Block IDs are stored as 16-byte UUID binary representation (no dashes).
// Data is serialized as BSON for generic data storage.
// Head blocks file remains in JSON format for now.
//

//
// Details of a block without the data
//
export interface IBlockDetails {
    _id: string;           // Unique block identifier (UUID)
    prevBlocks: string[];  // Array of previous block IDs
}

//
// Complete block with data
//
export interface IBlock<DataT> extends IBlockDetails {
    data: DataT;           // The actual data payload
}

//
// BlockGraph implementation for managing content-addressable blocks
//
export class BlockGraph<DataT extends readonly unknown[]> {
    private blockMap = new Map<string, IBlock<DataT>>();  // In-memory block cache
    private headBlockIds: string[] = [];                  // Current head blocks
    
    private static readonly BLOCK_VERSION = 1;             // Binary format version
    
    constructor(private storage: IStorage) {}

    //
    // Convert UUID string to 16-byte binary representation
    //
    private static uuidToBytes(uuidStr: string): Buffer {
        const hex = uuidStr.replace(/-/g, '');
        return Buffer.from(hex, 'hex');
    }

    //
    // Convert 16-byte binary representation to UUID string
    //
    private static bytesToUuid(bytes: Buffer): string {
        const hex = bytes.toString('hex');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
    }

    //
    // Load head blocks from persistent storage
    //
    async loadHeadBlocks(): Promise<void> {
        try {
            const headBlocksData = await this.storage.read('head-blocks.json');
            if (headBlocksData) {
                const headBlocks = JSON.parse(headBlocksData.toString('utf8'));
                this.headBlockIds = headBlocks.headBlockIds || [];
            }
        } catch (error) {
            // File doesn't exist or is corrupted, start with empty head blocks
            this.headBlockIds = [];
        }
    }

    //
    // Get current head block IDs
    //
    getHeadBlockIds(): string[] {
        return [...this.headBlockIds];
    }

    //
    // Get current head block objects
    //
    async getHeadBlocks(): Promise<IBlock<DataT>[]> {
        const headBlocks: IBlock<DataT>[] = [];
        for (const blockId of this.headBlockIds) {
            const block = await this.getBlock(blockId);
            if (block) {
                headBlocks.push(block);
            }
        }
        return headBlocks;
    }

    //
    // Check if block exists (memory or storage)
    //
    async hasBlock(id: string): Promise<boolean> {
        if (this.blockMap.has(id)) {
            return true;
        }
        
        try {
            const blockData = await this.storage.read(`blocks/${id}`);
            return !!blockData;
        } catch (error) {
            return false;
        }
    }

    //
    // Retrieve block, loading from storage if needed
    //
    async getBlock(id: string): Promise<IBlock<DataT> | undefined> {
        // Check memory cache first
        if (this.blockMap.has(id)) {
            return this.blockMap.get(id);
        }

        // Load from binary format
        try {
            const blockData = await this.storage.read(`blocks/${id}`);
            if (blockData && blockData.length >= 12) {
                const block = this.deserializeBlock(blockData);
                this.blockMap.set(id, block); // Cache it
                return block;
            }
        } catch (error) {
            // Block doesn't exist
        }
        
        return undefined;
    }

    //
    // Serialize block to binary format
    //
    private serializeBlock(block: IBlock<DataT>): Buffer {
        // Serialize data to BSON (wrap arrays since BSON doesn't support root arrays)
        const bsonData = BSON.serialize({ d: block.data });
        
        // Calculate total size
        const totalSize = 4 + 16 + 4 + (block.prevBlocks.length * 16) + 4 + bsonData.length;
        
        // Create buffer and write data
        const buffer = Buffer.alloc(totalSize);
        let offset = 0;
        
        // Write version (4 bytes LE)
        buffer.writeUInt32LE(BlockGraph.BLOCK_VERSION, offset);
        offset += 4;
        
        // Write block ID (16 bytes)
        const blockIdBytes = BlockGraph.uuidToBytes(block._id);
        blockIdBytes.copy(buffer, offset);
        offset += 16;
        
        // Write previous blocks count (4 bytes LE)
        buffer.writeUInt32LE(block.prevBlocks.length, offset);
        offset += 4;
        
        // Write previous block IDs (N*16 bytes)
        for (const prevBlock of block.prevBlocks) {
            const prevBlockBytes = BlockGraph.uuidToBytes(prevBlock);
            prevBlockBytes.copy(buffer, offset);
            offset += 16;
        }
        
        // Write data length (4 bytes LE)
        buffer.writeUInt32LE(bsonData.length, offset);
        offset += 4;

        //
        //TODO: For better binary data packing, hard code the database operations in the binary format instead of using BSON.
        //
        
        // Write BSON data
        Buffer.from(bsonData).copy(buffer, offset);
        
        return buffer;
    }

    //
    // Deserialize block from binary format
    //
    private deserializeBlock(buffer: Buffer): IBlock<DataT> {
        let offset = 0;
        
        // Read version (4 bytes LE)
        const version = buffer.readUInt32LE(offset);
        offset += 4;
        
        if (version !== BlockGraph.BLOCK_VERSION) {
            throw new Error(`Unsupported block version: ${version}`);
        }
        
        // Read block ID (16 bytes)
        const blockIdBytes = buffer.subarray(offset, offset + 16);
        const blockId = BlockGraph.bytesToUuid(blockIdBytes);
        offset += 16;
        
        // Read previous blocks count (4 bytes LE)
        const prevCount = buffer.readUInt32LE(offset);
        offset += 4;
        
        // Read previous block IDs (N*16 bytes)
        const prevBlocks: string[] = [];
        for (let i = 0; i < prevCount; i++) {
            const prevIdBytes = buffer.subarray(offset, offset + 16);
            prevBlocks.push(BlockGraph.bytesToUuid(prevIdBytes));
            offset += 16;
        }
        
        // Read data length (4 bytes LE)
        const dataLength = buffer.readUInt32LE(offset);
        offset += 4;
        
        // Read and deserialize BSON data
        const bsonData = buffer.subarray(offset, offset + dataLength);
        const deserializedData = BSON.deserialize(bsonData);
        // Unwrap array that was wrapped during serialization
        const data = deserializedData.d as DataT;
        
        return {
            _id: blockId,
            prevBlocks: prevBlocks,
            data: data
        };
    }

    //
    // Create and commit a new block
    //
    async commitBlock(data: DataT): Promise<IBlock<DataT>> {
        const blockId = uuid();
        
        const block: IBlock<DataT> = {
            _id: blockId,
            prevBlocks: [...this.headBlockIds], // Link to current head blocks
            data: data
        };

        // Store the block
        await this.storeBlock(block);
        
        // Update head blocks to point to new block
        this.headBlockIds = [blockId];
        await this.storeHeadBlocks();

        return block;
    }

    //
    // Integrate external block from another node
    //
    async integrateBlock(block: IBlock<DataT>): Promise<void> {
        // Store the block
        await this.storeBlock(block);
        
        // Update head blocks by removing blocks that are now predecessors
        const newHeadBlocks = this.headBlockIds.filter(headId => 
            !block.prevBlocks.includes(headId)
        );
        
        // Add this block as a new head if it's not already there
        if (!newHeadBlocks.includes(block._id)) {
            newHeadBlocks.push(block._id);
        }
        
        this.headBlockIds = newHeadBlocks;
        await this.storeHeadBlocks();
    }

    //
    // Store block to persistent storage
    //
    private async storeBlock(block: IBlock<DataT>): Promise<void> {
        this.blockMap.set(block._id, block);
        const binaryData = this.serializeBlock(block);
        await this.storage.write(`blocks/${block._id}`, undefined, binaryData);
    }

    //
    // Store head block references to persistent storage
    //
    private async storeHeadBlocks(): Promise<void> {
        const headBlocksData = {
            headBlockIds: this.headBlockIds,
            lastUpdated: new Date().toISOString()
        };
        const headBlocksJson = JSON.stringify(headBlocksData, null, 2);
        await this.storage.write('head-blocks.json', undefined, Buffer.from(headBlocksJson, 'utf8'));
    }
}