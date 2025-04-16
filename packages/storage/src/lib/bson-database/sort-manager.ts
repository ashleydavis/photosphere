//
// Manages the creation and usage of sort indexes for collections
//

import { IStorage } from '../storage';
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

export class SortManager {
    private storage: IStorage;
    private baseDirectory: string;
    private sortIndexes: Map<string, SortIndex<any>> = new Map();
    private defaultPageSize: number;

    constructor(options: ISortManagerOptions) {
        this.storage = options.storage;
        this.baseDirectory = options.baseDirectory;
        this.defaultPageSize = options.defaultPageSize || 1000;
    }

    // Generate a unique key for each sort index
    private getSortIndexKey(collectionName: string, fieldName: string, direction: 'asc' | 'desc'): string {
        return `${collectionName}:${fieldName}:${direction}`;
    }

    // Get an existing sort index (public version)
    async getSortIndex<RecordT extends IRecord>(
        collectionName: string,
        fieldName: string,
        direction: 'asc' | 'desc'
    ): Promise<SortIndex<RecordT> | undefined> {
        const key = this.getSortIndexKey(collectionName, fieldName, direction);

        // Check if this index is already in memory
        if (this.sortIndexes.has(key)) {
            return this.sortIndexes.get(key);
        }

        // Check if the index exists on disk
        const indexPath = `${this.baseDirectory}/sort_indexes/${collectionName}/${fieldName}_${direction}`;
        if (await this.storage.dirExists(indexPath)) {
            // Create a new sort index but don't initialize it
            const sortIndex = new SortIndex<RecordT>({
                storage: this.storage,
                baseDirectory: this.baseDirectory,
                collectionName,
                fieldName,
                direction
            });

            // Cache in memory
            this.sortIndexes.set(key, sortIndex);

            return sortIndex;
        }

        return undefined;
    }

    // Create or get an existing sort index (private version)
    private async createOrGetSortIndex<RecordT extends IRecord>(
        collection: IBsonCollection<RecordT>,
        collectionName: string,
        fieldName: string,
        direction: 'asc' | 'desc',
        pageSize?: number
    ): Promise<SortIndex<RecordT> | undefined> {
        const key = this.getSortIndexKey(collectionName, fieldName, direction);

        // Check if this index is already in memory
        if (this.sortIndexes.has(key)) {
            return this.sortIndexes.get(key);
        }

        // Create a new sort index
        const sortIndex = new SortIndex<RecordT>({
            storage: this.storage,
            baseDirectory: this.baseDirectory,
            collectionName,
            fieldName,
            direction,
            pageSize: pageSize || this.defaultPageSize
        });

        // Initialize if needed
        if (!await sortIndex.isInitialized()) {
            await sortIndex.initialize(collection);
        }

        // Cache in memory
        this.sortIndexes.set(key, sortIndex);

        return sortIndex;
    }

    // Get sorted records with pagination
    async getSortedRecords<RecordT extends IRecord>(
        collection: IBsonCollection<RecordT>,
        collectionName: string,
        fieldName: string,
        options?: {
            direction?: 'asc' | 'desc';
            page?: number;
            pageSize?: number;
        }
    ): Promise<ISortResult<RecordT>> {
        const direction = options?.direction || 'asc';
        const page = options?.page || 1;
        const pageSize = options?.pageSize || this.defaultPageSize;

        // Get or create the sort index
        const sortIndex = await this.createOrGetSortIndex<RecordT>(
            collection,
            collectionName,
            fieldName,
            direction,
            pageSize
        );

        if (!sortIndex) {
            return {
                records: [],
                totalRecords: 0,
                currentPage: 1,
                totalPages: 0,               
            };
        }

        // Get the requested page
        return await sortIndex.getPage(collection, page);
    }

    // Rebuild a specific sort index
    async rebuildSortIndex<RecordT extends IRecord>(
        collection: IBsonCollection<RecordT>,
        collectionName: string,
        fieldName: string,
        direction: 'asc' | 'desc'
    ): Promise<void> {
        const key = this.getSortIndexKey(collectionName, fieldName, direction);

        // Remove from memory cache if it exists
        if (this.sortIndexes.has(key)) {
            this.sortIndexes.delete(key);
        }

        // Create and initialize the index
        const sortIndex = await this.createOrGetSortIndex<RecordT>(
            collection,
            collectionName,
            fieldName,
            direction,
            this.defaultPageSize
        );

        if (!sortIndex) {
            return;
        }

        await sortIndex.delete(); // Delete the existing index
        await sortIndex.initialize(collection); // Rebuild
    }

    // List available sort indexes for a collection
    async listSortIndexes(collectionName: string): Promise<Array<{
        fieldName: string;
        direction: 'asc' | 'desc';
    }>> {
        const collectionIndexPath = `${this.baseDirectory}/sort_indexes/${collectionName}`;

        if (!await this.storage.dirExists(collectionIndexPath)) {
            return [];
        }

        const result = await this.storage.listFiles(collectionIndexPath, 1000);
        const directories = result.names || [];

        const sortIndexes: Array<{fieldName: string; direction: 'asc' | 'desc'}> = [];

        for (const dir of directories) {
            // Parse the directory name, which should be in format "fieldname_direction"
            const match = dir.match(/^(.+)_(asc|desc)$/);
            if (match) {
                sortIndexes.push({
                    fieldName: match[1],
                    direction: match[2] as 'asc' | 'desc'
                });
            }
        }

        return sortIndexes;
    }

    // Delete a sort index
    async deleteSortIndex(
        collectionName: string,
        fieldName: string,
        direction: 'asc' | 'desc'
    ): Promise<boolean> {
        const key = this.getSortIndexKey(collectionName, fieldName, direction);

        // Remove from memory cache
        if (this.sortIndexes.has(key)) {
            const sortIndex = this.sortIndexes.get(key);
            if (sortIndex) {
                await sortIndex.delete();
                this.sortIndexes.delete(key);
            }
        } else {
            // If not in memory, try to delete from disk
            const indexPath = `${this.baseDirectory}/sort_indexes/${collectionName}/${fieldName}_${direction}`;
            if (await this.storage.dirExists(indexPath)) {
                await this.storage.deleteDir(indexPath);
            } else {
                return false; // The index doesn't exist
            }
        }

        return true;
    }

    // Delete all sort indexes for a collection
    async deleteAllSortIndexes(collectionName: string): Promise<void> {
        // Remove from memory cache
        for (const [key, sortIndex] of this.sortIndexes.entries()) {
            if (key.startsWith(`${collectionName}:`)) {
                await sortIndex.delete();
                this.sortIndexes.delete(key);
            }
        }

        // Delete from disk
        const collectionIndexPath = `${this.baseDirectory}/sort_indexes/${collectionName}`;
        if (await this.storage.dirExists(collectionIndexPath)) {
            await this.storage.deleteDir(collectionIndexPath);
        }
    }
}