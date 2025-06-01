//
// Manages the creation and usage of sort indexes for collections
//

import { IStorage } from 'storage';
import { IBsonCollection, IRecord } from './collection';
import { SortIndex, ISortResult, SortDataType, SortDirection } from './sort-index';

export interface ISortManagerOptions {
    // Interface to the file storage system
    storage: IStorage;

    // The base directory where all sort indexes are stored
    baseDirectory: string;

    // Default page size for paginated results
    defaultPageSize?: number;
}

export class SortManager<RecordT extends IRecord> {
    private storage: IStorage;
    private baseDirectory: string;
    private sortIndexes: Map<string, any> = new Map();
    private defaultPageSize: number;
    
    constructor(options: ISortManagerOptions, private readonly collection: IBsonCollection<RecordT>, private readonly collectionName: string) {
        this.storage = options.storage;
        this.baseDirectory = options.baseDirectory;
        this.defaultPageSize = options.defaultPageSize || 1000;
    }
    
    //
    // Generates a unique key for each sort index.
    //
    private getSortIndexKey(fieldName: string, direction: SortDirection): string {
        return `${this.collectionName}:${fieldName}:${direction}`;
    }
    
    //
    // Determines if a sort index exists or not.
    //
    async hasSortIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        // Check if this index is already in memory.
        if (this.sortIndexes.has(key)) {
            return true;
        }
        
        // Check if the index exists on disk.
        const indexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}/${fieldName}_${direction}`;
        return await this.storage.dirExists(indexPath);
    }

    //
    // Gets a sort index by field name and direction.
    //
    async getSortIndex( fieldName: string, direction: SortDirection): Promise<SortIndex<RecordT> | undefined> {
        const key = this.getSortIndexKey(fieldName, direction);
        return this.sortIndexes.get(key);
    }
        
    //
    // Create a existing sort index.
    //
    private async createSortIndex(fieldName: string, direction: SortDirection, type?: SortDataType, pageSize?: number): Promise<SortIndex<RecordT>> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        let sortIndex = this.sortIndexes.get(key);
        if (sortIndex) {
            // Sort index exists in memory.
            if (sortIndex.type !== type) {
                throw new Error(`Sort index for field "${fieldName}" in direction "${direction}" already exists with a different type: ${sortIndex.type}. Expected: ${type}`);
            }
            return sortIndex;
        }
        
        sortIndex = new SortIndex<RecordT>({
            storage: this.storage,
            baseDirectory: this.baseDirectory,
            collectionName: this.collectionName,
            fieldName,
            direction,
            pageSize: pageSize || this.defaultPageSize,
            type
        },  this.collection);
               
        this.sortIndexes.set(key, sortIndex);
        
        return sortIndex;
    }
    
    //
    // Get sorted records with pagination.
    //
    async getSortedRecords(fieldName: string, direction: SortDirection, pageId?: string): Promise<ISortResult<RecordT>> {
        const sortIndex = await this.getSortIndex(fieldName, direction);
        if (!sortIndex) {
            throw new Error(`Sort index for field "${fieldName}" in direction "${direction}" does not exist.`);
        }
        
        return await sortIndex.getPage(pageId);
    }
    
    //
    // Builds the sort index if it doesn't exist.
    //
    async ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        const sortIndex = await this.createSortIndex(fieldName, direction, type, this.defaultPageSize);
        await sortIndex.init();
    }
    
    // List available sort indexes for a collection
    async listSortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection }>> {
        const collectionIndexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}`;
        
        if (!await this.storage.dirExists(collectionIndexPath)) {
            return [];
        }

        
        const result = await this.storage.listDirs(collectionIndexPath, 1000);
        const directories = result.names || [];
        
        const sortIndexes: Array<{fieldName: string; direction: SortDirection}> = [];
        
        for (const dir of directories) {
            // Parse the directory name, which should be in format "fieldname_direction"
            const match = dir.match(/^(.+)_(asc|desc)$/);
            if (match) {
                const indexInfo = {
                    fieldName: match[1],
                    direction: match[2] as SortDirection,
                };
                sortIndexes.push(indexInfo);
            }
        }

        return sortIndexes;
    }
    
    //
    // Delete a sort index.
    //
    async deleteSortIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        //
        // Remove from memory cache.
        //
        if (this.sortIndexes.has(key)) {
            const sortIndex = this.sortIndexes.get(key);
            await sortIndex.delete();
            this.sortIndexes.delete(key);
        } 
        else {
            // If not in memory, try to delete from disk.
            const indexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}/${fieldName}_${direction}`;
            if (await this.storage.dirExists(indexPath)) {
                await this.storage.deleteDir(indexPath);
            } 
            else {
                return false; // The index doesn't exist
            }
        }

        return true;
    }
    
    //
    // Delete all sort indexes for a collection.
    //
    async deleteAllSortIndexes(): Promise<void> {
        // Remove from memory cache.
        for (const [key, sortIndex] of this.sortIndexes.entries()) {
            if (key.startsWith(`${this.collectionName}:`)) {
                await sortIndex.delete();
                this.sortIndexes.delete(key);
            }
        }
        
        // Delete from disk.
        const collectionIndexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}`;
        if (await this.storage.dirExists(collectionIndexPath)) {
            await this.storage.deleteDir(collectionIndexPath);
        }
    }
    
    //
    // Shut down all sort indexes, saving any dirty pages.
    //
    async shutdown(): Promise<void> {
        // Call shutdown on all sort indexes.
        for (const sortIndex of this.sortIndexes.values()) {
            await sortIndex.shutdown();
        }
        
        // Clear the cache.
        this.sortIndexes.clear();
    }

    //
    // Adds a record to all sort indexes for this collection.
    //    
    async addRecord(record: RecordT): Promise<void> {
        for (const sortIndex of this.sortIndexes.values()) {
            await sortIndex.addRecord(record);
        }
    }

    // 
    // Updates a record in all sort indexes.
    //
    async updateRecord(updatedRecord: RecordT, oldRecord: RecordT | undefined): Promise<void> {
        for (const sortIndex of this.sortIndexes.values()) {
            await sortIndex.updateRecord(updatedRecord, oldRecord);
        }
    }        

    //
    // Deletes a record from all existing sort indexes.
    //
    async deleteRecord(recordId: string, record: RecordT): Promise<void> {                
        for (const sortIndex of this.sortIndexes.values()) {
            await sortIndex.deleteRecord(recordId, record);
        }
    }
}