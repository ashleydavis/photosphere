import { v4 as uuid } from 'uuid';
import { IStorage } from 'storage';
import { DatabaseUpdate } from './database-update';

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
export class BlockGraph<DataT> {
    private blockMap = new Map<string, IBlock<DataT>>();  // In-memory block cache
    private headBlockIds: string[] = [];                  // Current head blocks
    
    constructor(private storage: IStorage) {}

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
            const blockData = await this.storage.read(`blocks/${id}.json`);
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

        // Load from storage
        try {
            const blockData = await this.storage.read(`blocks/${id}.json`);
            if (blockData) {
                const block = JSON.parse(blockData.toString('utf8')) as IBlock<DataT>;
                this.blockMap.set(id, block); // Cache it
                return block;
            }
        } catch (error) {
            // Block doesn't exist
        }
        
        return undefined;
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
        const blockJson = JSON.stringify(block, null, 2);
        await this.storage.write(`blocks/${block._id}.json`, 'application/json', Buffer.from(blockJson, 'utf8'));
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
        await this.storage.write('head-blocks.json', 'application/json', Buffer.from(headBlocksJson, 'utf8'));
    }
}