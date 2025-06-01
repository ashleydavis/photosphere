//
// Manages the creation and usage of sort indexes for collections
//

import { IStorage } from 'storage';
import { IBsonCollection, IRecord } from './collection';
import { SortIndex, ISortResult } from './sort-index';

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
    private getSortIndexKey(fieldName: string, direction: 'asc' | 'desc'): string {
        return `${this.collectionName}:${fieldName}:${direction}`;
    }
    
    //
    // Get an existing sort index (public version).,
    //
    async getSortIndex(fieldName: string, direction: 'asc' | 'desc', type?: 'date'): Promise<SortIndex<RecordT> | undefined> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        // Check if this index is already in memory.
        if (this.sortIndexes.has(key)) {
            return this.sortIndexes.get(key);
        }
        
        // Check if the index exists on disk.
        const indexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}/${fieldName}_${direction}`;
        if (await this.storage.dirExists(indexPath)) {
            // Create a new sort index but don't initialize it.
            const sortIndex = new SortIndex<RecordT>({
                storage: this.storage,
                baseDirectory: this.baseDirectory,
                collectionName: this.collectionName,
                fieldName,
                direction,
                type
            }, this.collection);
            
            // Cache in memory.
            this.sortIndexes.set(key, sortIndex);

            return sortIndex;
        }

        return undefined;
    }
    
    //
    // Create or get an existing sort index (private version).
    //
    private async createOrGetSortIndex(
        fieldName: string,
        direction: 'asc' | 'desc',
        pageSize?: number,
        type?: "date" | "string" | "number"
    ): Promise<SortIndex<RecordT>> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        // Check if this index is already in memory.
        if (this.sortIndexes.has(key)) {
            return this.sortIndexes.get(key);
        }
        
        // Create a new sort index.
        const sortIndex = new SortIndex<RecordT>({
            storage: this.storage,
            baseDirectory: this.baseDirectory,
            collectionName: this.collectionName,
            fieldName,
            direction,
            pageSize: pageSize || this.defaultPageSize,
            type
        },  this.collection);

               
        // Cache in memory.
        this.sortIndexes.set(key, sortIndex);
        
        return sortIndex;
    }
    
    //
    // Get sorted records with pagination.
    //
    async getSortedRecords(
        fieldName: string,
        options?: {
            direction?: 'asc' | 'desc';
            page?: number;
            pageSize?: number;
            pageId?: string;
            type?: 'date'; // Optional type for sorting
        }
    ): Promise<ISortResult<RecordT>> {
        const direction = options?.direction || 'asc';
        const pageSize = options?.pageSize || this.defaultPageSize;
        const type = options?.type;
        
        // Get or create the sort index.
        const sortIndex = await this.createOrGetSortIndex(fieldName, direction, pageSize, type);
        
        // If page number is specified, convert to page ID
        if (options?.page !== undefined) {
            // For backward compatibility, handle page numbers by fetching pages in sequence
            if (options.page < 1) {
                throw new Error('Page number must be greater than 0');
            }
            
            // Get the first page, then follow next links until we reach the target page
            let currentPage = 1;
            let result = await sortIndex.getPage('');
            
            while (currentPage < options.page && result.nextPageId) {
                result = await sortIndex.getPage(result.nextPageId);
                currentPage++;
            }
            
            return result;
        }
        
        // Use pageId if provided, otherwise get the first page
        const pageId = options?.pageId || '';
        return await sortIndex.getPage(pageId);
    }
    
    //
    // Rebuild a specific sort index.
    //
    async rebuildSortIndex(
        fieldName: string,
        direction: 'asc' | 'desc',
        type?: "date" | "string" | "number"
    ): Promise<void> {
        const key = this.getSortIndexKey(fieldName, direction);
        
        // Remove from memory cache if it exists
        if (this.sortIndexes.has(key)) {
            this.sortIndexes.delete(key);
        }
        
        // Create and initialize the index
        const sortIndex = await this.createOrGetSortIndex(fieldName, direction, this.defaultPageSize, type);
        
        await sortIndex.delete(); // Delete the existing index.
        await sortIndex.build(); // Rebuild.
    }
    
    // List available sort indexes for a collection
    async listSortIndexes(): Promise<Array<{
        fieldName: string;
        direction: 'asc' | 'desc';
        type?: 'date';
    }>> {
        const collectionIndexPath = `${this.baseDirectory}/sort_indexes/${this.collectionName}`;
        
        if (!await this.storage.dirExists(collectionIndexPath)) {
            return [];
        }

        
        const result = await this.storage.listDirs(collectionIndexPath, 1000);
        const directories = result.names || [];
        
        const sortIndexes: Array<{fieldName: string; direction: 'asc' | 'desc'; type?: 'date'}> = [];
        
        for (const dir of directories) {
            // Parse the directory name, which should be in format "fieldname_direction"
            const match = dir.match(/^(.+)_(asc|desc)$/);
            if (match) {
                const indexInfo = {
                    fieldName: match[1],
                    direction: match[2] as 'asc' | 'desc'
                };
                
                // Get the sort index to retrieve its type
                const sortIndex = await this.getSortIndex(indexInfo.fieldName, indexInfo.direction);
                if (sortIndex && 'type' in sortIndex) {
                    // This is a safe cast because we know the structure of SortIndex
                    const typedIndex = sortIndex as unknown as { type?: 'date' };
                    if (typedIndex.type) {
                        (indexInfo as any).type = typedIndex.type;
                    }
                }
                
                sortIndexes.push(indexInfo);
            }
        }

        return sortIndexes;
    }
    
    //
    // Delete a sort index.
    //
    async deleteSortIndex(
        fieldName: string,
        direction: 'asc' | 'desc'
    ): Promise<boolean> {
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
}