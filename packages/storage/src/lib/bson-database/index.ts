//
// Implements an index for a BSON collection
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { type IStorage } from '../storage';
import { retry } from 'utils';
import { IRecord } from './collection';

export interface IBsonIndexEntry {
    //
    // The value of the indexed field.
    //
    value: any;

    //
    // The IDs of records that have this value.
    //
    recordIds: string[];
}

export interface IBsonIndex<RecordT extends IRecord> {
    //
    // The name of the field that this index indexes
    //
    fieldName: string;

    //
    // Adds or updates an index entry for a record
    //
    indexRecord(record: RecordT): Promise<void>;

    //
    // Removes an index entry for a record
    //
    removeRecord(recordId: string): Promise<void>;

    //
    // Finds all record IDs that match the given field value
    //
    findByValue(value: any): Promise<string[]>;
    
    //
    // Gets all entries in the index
    //
    getAllEntries(): Promise<IBsonIndexEntry[]>;

    //
    // Writes all pending changes and shuts down the index
    //
    shutdown(): Promise<void>;
}

//
// Options for creating an index.
//
export interface IBsonIndexOptions {
    //
    // Interface to the file storage system.
    //
    storage: IStorage;

    //
    // The directory where the collection is stored.
    //
    directory: string;

    //
    // The name of the field to index.
    //
    fieldName: string;
}

//
// Internal structure to store index entries
//
interface IIndexEntry {
    //
    // The value of the indexed field
    //
    value: any;

    //
    // The IDs of records that have this value
    //
    recordIds: string[];
}

export class BsonIndex<RecordT extends IRecord> implements IBsonIndex<RecordT> {
    private storage: IStorage;
    private directory: string;
    public readonly fieldName: string;
    private entries: Map<string, IIndexEntry> = new Map();
    private dirty: boolean = false;
    private loaded: boolean = false;

    constructor(options: IBsonIndexOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.fieldName = options.fieldName;
    }

    //
    // Serializes a value to a string key for the index map
    //
    private serializeValue(value: any): string {
        if (value === null || value === undefined) {
            return '_null_';
        }
        
        if (typeof value === 'string') {
            return `s:${value}`;
        }
        
        if (typeof value === 'number') {
            return `n:${value}`;
        }
        
        if (typeof value === 'boolean') {
            return `b:${value}`;
        }
        
        if (typeof value === 'object') {
            // For objects, serialize to BSON string and hash
            const bson = BSON.serialize(value);
            const hash = crypto.createHash('md5').update(bson).digest('hex');
            return `o:${hash}`;
        }
        
        // Default fallback
        return `u:${String(value)}`;
    }

    //
    // Gets the path to the index file
    //
    private getIndexFilePath(): string {
        return `${this.directory}/index/${this.fieldName}.dat`;
    }   

    //
    // Loads the index from storage if not already loaded
    //
    private async ensureLoaded(): Promise<void> {
        if (this.loaded) {
            return;
        }

        const indexFilePath = this.getIndexFilePath();
        
        if (await this.storage.fileExists(indexFilePath)) {
            const fileData = await this.storage.read(indexFilePath);
            
            if (fileData && fileData.length > 0) {
                // Skip the 32-byte checksum at the end
                const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);
                
                // Calculate checksum of the data
                const storedChecksum = fileData.subarray(fileData.length - 32);
                const calculatedChecksum = crypto.createHash('sha256').update(dataWithoutChecksum).digest();
                
                // Verify checksum
                if (!calculatedChecksum.equals(storedChecksum)) {
                    console.error('Index checksum verification failed');
                    this.entries = new Map();
                    this.dirty = true;
                } 
                else {
                    // Read version number (first 4 bytes)
                    const version = dataWithoutChecksum.readUInt32LE(0);
                    
                    if (version === 1) {
                        // Skip the version number to get to the BSON data
                        const bsonData = dataWithoutChecksum.subarray(4);
                        
                        // Deserialize the index data
                        const indexData = BSON.deserialize(bsonData) as { entries: Array<IIndexEntry> };
                        
                        // Convert array to map
                        this.entries = new Map();
                        for (const entry of indexData.entries) {
                            const key = this.serializeValue(entry.value);
                            this.entries.set(key, entry);
                        }
                        console.log(`Loaded index ${this.fieldName} (version ${version})`);
                    } 
                    else {
                        console.error(`Unsupported index version: ${version}`);
                        this.entries = new Map();
                        this.dirty = true;
                    }
                }
            }
        }
        
        this.loaded = true;
    }

    //
    // Saves the index to storage
    //
    private async saveIndex(): Promise<void> {
        if (!this.dirty) {
            return;
        }
        
        const indexFilePath = this.getIndexFilePath();
        
        // Convert map to array for serialization
        const entriesArray = Array.from(this.entries.values());
        
        // Serialize to BSON
        const indexData = { entries: entriesArray };
        const bsonData = BSON.serialize(indexData);
        
        // Add a version number (4 bytes) at the beginning
        const versionBuffer = Buffer.alloc(4);
        versionBuffer.writeUInt32LE(1, 0); // Version 1
        
        // Combine version and BSON data
        const versionedData = Buffer.concat([versionBuffer, bsonData]);
        
        // Calculate checksum of the versioned data
        const checksum = crypto.createHash('sha256').update(versionedData).digest();
        
        // Combine versioned data and checksum
        const dataWithChecksum = Buffer.concat([versionedData, checksum]);
        
        // Write to storage (this will automatically create directories as needed)
        await this.storage.write(indexFilePath, undefined, dataWithChecksum);
        
        // Verify the write
        const readBuffer = await retry(() => this.storage.read(indexFilePath));
        if (!readBuffer) {
            throw new Error('Index verification failed (file not found)');
        }
        
        if (readBuffer.length !== dataWithChecksum.length) {
            throw new Error(`Index verification failed (size mismatch: ${readBuffer.length} vs ${dataWithChecksum.length})`);
        }
        
        const writtenData = readBuffer.subarray(0, readBuffer.length - 32);
        const computedChecksum = crypto.createHash('sha256').update(writtenData).digest();
        
        if (!computedChecksum.equals(checksum)) {
            throw new Error('Index verification failed (checksum mismatch)');
        }
        
        this.dirty = false;
    }

    //
    // Adds or updates an index entry for a record
    //
    async indexRecord(record: RecordT): Promise<void> {
        await this.ensureLoaded();
        
        // Extract the value to index
        const value = record[this.fieldName];
        const recordId = record._id;
        
        // Don't index if the field doesn't exist
        if (value === undefined) {
            return;
        }
        
        // Remove record from any existing entries first (to handle updates)
        await this.removeRecord(recordId);
        
        // Create or update the entry
        const key = this.serializeValue(value);
        const entry = this.entries.get(key);
        
        if (entry) {
            // Add to existing entry if not already present
            if (!entry.recordIds.includes(recordId)) {
                entry.recordIds.push(recordId);
                this.dirty = true;
            }
        } 
        else {
            // Create new entry
            this.entries.set(key, {
                value: value,
                recordIds: [recordId]
            });
            this.dirty = true;
        }
        
        // Save the index if it's dirty
        await this.saveIndex();
    }

    //
    // Removes an index entry for a record
    //
    async removeRecord(recordId: string): Promise<void> {
        await this.ensureLoaded();
        
        let modified = false;
        
        // Check all entries for the record ID
        for (const [key, entry] of this.entries.entries()) {
            const index = entry.recordIds.indexOf(recordId);
            
            if (index !== -1) {
                // Remove the record ID from the entry
                entry.recordIds.splice(index, 1);
                modified = true;
                
                // Remove the entry entirely if no more record IDs
                if (entry.recordIds.length === 0) {
                    this.entries.delete(key);
                }
            }
        }
        
        if (modified) {
            this.dirty = true;
            await this.saveIndex();
        }
    }

    //
    // Finds all record IDs that match the given field value
    //
    async findByValue(value: any): Promise<string[]> {
        await this.ensureLoaded();
        
        const key = this.serializeValue(value);
        const entry = this.entries.get(key);
        
        if (!entry) {
            return [];
        }
        
        return entry.recordIds.slice(); // Return a copy of the array
    }
    
    //
    // Gets all entries in the index
    //
    async getAllEntries(): Promise<IBsonIndexEntry[]> {
        // Make sure the index is loaded
        await this.ensureLoaded();
        
        // Convert the entries map to an array of objects
        // Return copies of the arrays to prevent modification
        return Array.from(this.entries.values()).map(entry => ({
            value: entry.value,
            recordIds: [...entry.recordIds]
        }));
    }

    //
    // Writes all pending changes and shuts down the index
    //
    async shutdown(): Promise<void> {
        await this.saveIndex();
    }
}