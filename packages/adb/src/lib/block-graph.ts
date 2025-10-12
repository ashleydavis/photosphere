import { v4 as uuid } from 'uuid';
import { IStorage } from 'storage';
import { BSON } from 'bson';
import { ISerializer, IDeserializer, save, load } from 'serialization';

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

export interface IDataElement {
    timestamp: number; // Unix timestamp of the update.
}

//
// Complete block with data
//
export interface IBlock<DataElementT extends IDataElement> extends IBlockDetails {
    data: DataElementT[]; // The actual data payload.
}

//
// BlockGraph implementation for managing content-addressable blocks
//
export class BlockGraph<DataElementT extends IDataElement> {
    private headBlockIds: string[] = [];                  // Current head blocks
    
    private static readonly BLOCK_VERSION = 1;             // Binary format version
    
    constructor(private storage: IStorage, private metadataStorage: IStorage) {}

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
        const headBlocksData = await this.metadataStorage.read('head-blocks.json');
        if (headBlocksData) {
            const headBlocks = JSON.parse(headBlocksData.toString('utf8'));
            this.headBlockIds = headBlocks.headBlockIds || [];
        }
        else {
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
    async getHeadBlocks(): Promise<IBlock<DataElementT>[]> {
        const headBlocks: IBlock<DataElementT>[] = [];
        for (const blockId of this.headBlockIds) {
            const block = await this.getBlock(blockId);
            if (block) {
                headBlocks.push(block);
            }
        }
        return headBlocks;
    }

    //
    // Check if block exists in storage
    //
    async hasBlock(id: string): Promise<boolean> {
        try {
            const blockData = await this.storage.read(`blocks/${id}`);
            return !!blockData;
        } catch (error) {
            return false;
        }
    }

    //
    // Retrieve block from storage
    //
    async getBlock(id: string): Promise<IBlock<DataElementT> | undefined> {
        // Load from binary format using save/load interface
        const deserializers = {
            [BlockGraph.BLOCK_VERSION]: BlockGraph.deserializeBlock<DataElementT>
        };
        
        const block = await load<IBlock<DataElementT>>(
            this.storage,
            `blocks/${id}`,
            deserializers,
            undefined,
            undefined,
            { checksum: false }
        );
        
        return block;
    }

    //
    // Serializer function for save/load interface
    //
    private static serializeBlock<DataElementT extends IDataElement>(block: IBlock<DataElementT>, serializer: ISerializer): void {
        // Write block ID (16 bytes)
        const blockIdBytes = BlockGraph.uuidToBytes(block._id);
        serializer.writeBytes(blockIdBytes);
        
        // Write previous blocks count (4 bytes LE)
        serializer.writeUInt32(block.prevBlocks.length);
        
        // Write previous block IDs (N*16 bytes)
        for (const prevBlock of block.prevBlocks) {
            const prevBlockBytes = BlockGraph.uuidToBytes(prevBlock);
            serializer.writeBytes(prevBlockBytes);
        }
        
        // Serialize data to BSON (wrap arrays since BSON doesn't support root arrays)
        const bsonData = BSON.serialize({ d: block.data });
        
        // Write data length (4 bytes LE)
        serializer.writeUInt32(bsonData.length);

        //
        //TODO: For better binary data packing, hard code the database operations in the binary format instead of using BSON.
        //
        
        // Write BSON data
        serializer.writeBytes(Buffer.from(bsonData));
    }

    //
    // Deserializer function for save/load interface
    //
    private static deserializeBlock<DataElementT extends IDataElement>(deserializer: IDeserializer): IBlock<DataElementT> {
        // Read block ID (16 bytes)
        const blockIdBytes = deserializer.readBytes(16);
        const blockId = BlockGraph.bytesToUuid(blockIdBytes);
        
        // Read previous blocks count (4 bytes LE)
        const prevCount = deserializer.readUInt32();
        
        // Read previous block IDs (N*16 bytes)
        const prevBlocks: string[] = [];
        for (let i = 0; i < prevCount; i++) {
            const prevIdBytes = deserializer.readBytes(16);
            prevBlocks.push(BlockGraph.bytesToUuid(prevIdBytes));
        }
        
        // Read data length (4 bytes LE)
        const dataLength = deserializer.readUInt32();
        
        // Read and deserialize BSON data
        const bsonData = deserializer.readBytes(dataLength);
        const deserializedData = BSON.deserialize(bsonData);
        // Unwrap array that was wrapped during serialization
        const data = deserializedData.d as DataElementT[];
        
        return {
            _id: blockId,
            prevBlocks: prevBlocks,
            data: data
        };
    }

    //
    // Create and commit a new block
    //
    async commitBlock(data: DataElementT[]): Promise<IBlock<DataElementT>> {
        const blockId = uuid();
        
        const block: IBlock<DataElementT> = {
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
    async integrateBlock(block: IBlock<DataElementT>): Promise<void> {
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
    private async storeBlock(block: IBlock<DataElementT>): Promise<void> {
        await save(
            this.storage,
            `blocks/${block._id}`,
            block,
            BlockGraph.BLOCK_VERSION,
            BlockGraph.serializeBlock,
            { checksum: false }
        );
    }

    //
    // Store head block references to persistent storage
    //
    private async storeHeadBlocks(): Promise<void> {
        const headBlocksData = {
            headBlockIds: this.headBlockIds
        };
        const headBlocksJson = JSON.stringify(headBlocksData, null, 2);
        await this.metadataStorage.write('head-blocks.json', undefined, Buffer.from(headBlocksJson, 'utf8'));
    }

    //
    // Sets the head block (for tracking processed blocks)
    //
    async setHeadBlocks(headBlockIds: string[]): Promise<void> {
        this.headBlockIds = [...headBlockIds];
        await this.storeHeadBlocks();
    }

    //
    // Clears all head blocks
    //
    async clearHeadBlocks(): Promise<void> {
        this.headBlockIds = [];
        await this.storeHeadBlocks();
    }

    //
    // Gets the head hashes for database updates (same as head block IDs)
    //
    async getHeadHashes(): Promise<string[]> {
        return [...this.headBlockIds];
    }

    //
    // Sets the head hashes for database updates (same as head block IDs)
    //
    async setHeadHashes(headHashes: string[]): Promise<void> {
        this.headBlockIds = [...headHashes];
        await this.storeHeadBlocks();
    }

    //
    // Clears the head hashes (same as clearing head blocks)
    //
    async clearHeadHashes(): Promise<void> {
        this.headBlockIds = [];
        await this.storeHeadBlocks();
    }
}