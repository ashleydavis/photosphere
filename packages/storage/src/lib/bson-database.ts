//
// A database that stores BSON records in a sharded format.
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from './storage';
import { retry } from 'utils';

interface DatabaseOptions {
    storage: IStorage;
    directory: string;
    numShards?: number;
}

interface Record {
    _id: string;
    [key: string]: any;
}

export class BsonDatabase {
    private storage: IStorage;
    private directory: string;
    private numShards: number;
    private shardCache: Map<number, Record[]> = new Map();

    constructor(options: DatabaseOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.numShards = options.numShards || 100;
    }

    async shutdown(): Promise<void> {
        //todo: Flush any pending writes before shutdown
    }

    //
    // Determines the shard ID for a record based on its ID.
    //
    private generateShardId(recordId: string): number {
        const hash = crypto.createHash('md5').update(recordId).digest('hex');
        const decimal = parseInt(hash.substring(0, 8), 16);
        return decimal % this.numShards;
    }

    //
    // Calculate checksum for a buffer.
    //
    private calculateChecksum(buffer: Uint8Array): Buffer {
        return crypto.createHash('sha256').update(buffer).digest();
    }

    //
    // Saves the shard file to storage.
    //
    private async saveShardFile(shardFilePath: string, records: Record[]): Promise<void> {
        if (records.length === 0) {
            if (await this.storage.fileExists(shardFilePath)) {
                //
                // Delete empty files.
                //
                await this.storage.delete(shardFilePath);
            }
        }
        else {
            await this.writeBsonFile(shardFilePath, records);

            console.log(`Saved ${records.length} records to ${shardFilePath}`); //fio:
        }
    }

    //
    // Writes a shard to disk.
    //
    private async writeBsonFile(filePath: string, records: Record[]): Promise<void> {

        const buffers: Uint8Array[] = [];

        const header = Buffer.alloc(4 * 2);
        header.writeUInt32LE(1, 0); // Version
        header.writeUInt32LE(records.length, 4); // Record count
        buffers.push(header);

        for (const record of records) {
            const recordIdBuffer = Buffer.from(record._id.replace(/-/g, ''), 'hex');
            if (recordIdBuffer.length !== 16) {
                throw new Error(`Invalid record ID ${record._id} with length ${recordIdBuffer.length}`); //TODO: This gets triggered!
            }
            buffers.push(recordIdBuffer);

            const hexString = recordIdBuffer.toString('hex'); //fio:
            const recordId = [
                hexString.substring(0, 8),
                hexString.substring(8, 12),
                hexString.substring(12, 16),
                hexString.substring(16, 20),
                hexString.substring(20)
            ].join('-');
            if (recordId !== record._id) {
                throw new Error(`Record ID mismatch: ${recordId} vs ${record._id}`);
            }
            
            const recordBson = BSON.serialize(record);
            
            const recordHeader = Buffer.alloc(4);           
            recordHeader.writeUInt32LE(recordBson.length, 0);
            buffers.push(recordHeader);
            buffers.push(recordBson);
        }

        const allData = Buffer.concat(buffers);
        const allDataChecksum = this.calculateChecksum(allData);
        if (allDataChecksum.length !== 32) {
            throw new Error(`Checksum length mismatch: ${allDataChecksum.length}`);
        }
        const dataWithChecksum = Buffer.concat([allData, allDataChecksum]);

        //
        // Writes the file.
        //
        await this.storage.write(filePath, undefined, dataWithChecksum);

        //
        //TODO: This would be nice but not feasible at the moment for parallel writes.
        //
        
        // //
        // // Read the file back to verify it.
        // //
        // const readBuffer = await retry(() => this.storage.read(filePath));
        // if (!readBuffer) {
        //     throw new Error(`Verification failed (file not found)`);
        // }

        // //
        // // Check the file size matches.
        // //
        // if (readBuffer.length !== dataWithChecksum.length) {
        //     throw new Error(`Verification failed (size mismatch: ${readBuffer.length} vs ${dataWithChecksum.length})`);
        // }

        // //
        // // Then verify the checksum.
        // //
        // const writtenHeaderChecksum = readBuffer.slice(readBuffer.length-32);
        // if (!writtenHeaderChecksum.equals(allDataChecksum)) {
        //     throw new Error(`Verification failed (data checksum mismatch)`);
        // }
    }

    //
    // Loads all records from a shard file.
    //
    private async loadRecords(shardFilePath: string): Promise<Record[]> {
        
        let records: Record[] = [];

        if (await this.storage.fileExists(shardFilePath)) {
            // Read all records from the file
            const fileData = await this.storage.read(shardFilePath);
            if (fileData && fileData.length > 0) {

                const version = fileData.readUInt32LE(0); // Version

                const recordCount = fileData.readUInt32LE(4); // Record count
                let offset = 8; // Skip the version and record count.

                for (let i = 0; i < recordCount; i++) {
                    //
                    // Read 16 byte uuid.
                    //
                    const recordIdBuffer = fileData.subarray(offset, offset + 16);
                    const hexString = recordIdBuffer.toString('hex');
                    const recordId = [
                        hexString.substring(0, 8),
                        hexString.substring(8, 12),
                        hexString.substring(12, 16),
                        hexString.substring(16, 20),
                        hexString.substring(20)
                    ].join('-');

                    offset += 16;

                    //
                    // Read the record length.
                    //
                    const recordLength = fileData.readUInt32LE(offset);
                    offset += 4;

                    //
                    // Read and deserialize the record.
                    //
                    const recordData = fileData.subarray(offset, offset + recordLength);
                    const record = BSON.deserialize(recordData) as Record;
                    record._id = recordId;
                    records.push(record);
                    offset += recordLength;
                }
            }
        }

        return records;
    }



    //
    // Insert a new record into the database.
    //
    async insert(record: Record): Promise<void> {
        if (!record._id) {
            record._id = crypto.randomUUID();
        }

        // Determine which shard to store the record in.
        const shardId = this.generateShardId(record._id);
        const filePath = `${this.directory}/${shardId}`;
        
        let records = this.shardCache.get(shardId);
        if (records === undefined) {
            records = await this.loadRecords(filePath); //TODO: Could be an expensive operation. We don't need to load all records into memory.
            this.shardCache.set(shardId, records);
        }

        // Add the record to the existing file.
        records.push(record);

        // Save the updated file.
        await this.saveShardFile(filePath, records);
    }

    //
    // Finds one record by ID.
    //
    async findById(id: string): Promise<Record | undefined> {

        const shardId = this.generateShardId(id);
        const shardFilePath = `${this.directory}/${shardId}`;

        let records = this.shardCache.get(shardId);
        if (records === undefined) {
            records = await this.loadRecords(shardFilePath); //TODO: Could be an expensive operation. We don't need to load all records into memory.
            this.shardCache.set(shardId, records);
        }

        if (records.length === 0) {
            return undefined; // Empty file.
        }

        // Find the record with this ID.
        const record = records.find(e => e.id === id); //TDOO: Be good to do a fast lookup.
        if (!record) {
            return undefined; // Record not found
        }

        return record;
    }

    //
    // Iterate all records in the database without loading all into memory.
    //
    async *iterateRecords(): AsyncGenerator<Record, void, unknown> {

        let next: string | undefined = undefined;
        
        do {
            let result = await this.storage.listFiles(this.directory, 1000, next);
            let files = result.names || [];
            for (const file of files) {
                const buffer = await this.storage.read(`${this.directory}/${file}`);
                if (!buffer || buffer.length === 0) {
                    continue;
                }

                const version = buffer.readUInt32LE(0); // Version
                const recordCount = buffer.readUInt32LE(4); // Record count

                let offset = 8; // Skip the version and record count.
                
                for (let i = 0; i < recordCount; i++) {
                    //
                    // Read 16 byte uuid.
                    //
                    const recordId = buffer.subarray(offset, offset + 16);
                    const id = recordId.toString('hex').replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5');
                    offset += 16;

                    //
                    // Read the record length.
                    //
                    const recordLength = buffer.readUInt32LE(offset);
                    offset += 4;

                    //
                    // Read and deserialize the record.
                    //
                    const recordData = buffer.subarray(offset, offset + recordLength);
                    const record = BSON.deserialize(recordData) as Record;
                    record._id = id;
                    yield record;
                }
            }
            next = result.next;
        } while (next);
    }

    //
    // Gets all records in the database.
    //
    async findAll(): Promise<Record[]> {
        const results: Record[] = [];

        // Use the generator to process records one by one
        for await (const record of this.iterateRecords()) {
            results.push(record);
        }

        return results;
    }

    //
    // Updates a record.
    //
    // TODO: Would be good if this could do an upsert.
    //
    async update(id: string, updates: Partial<Record>): Promise<boolean> {

        //
        // Reads the shard.
        //
        const shardId = this.generateShardId(id);
        const shardFilePath = `${this.directory}/${shardId}`;

        let records = this.shardCache.get(shardId);
        if (records === undefined) {
            records = await this.loadRecords(shardFilePath); //TODO: Could be an expensive operation. We don't need to load all records into memory.
            this.shardCache.set(shardId, records);
        }

        //
        // Finds the record to update.
        //
        const recordIndex = records.findIndex(e => e._id === id); //todo: Be good to do a fast lookup.
        if (recordIndex < 0) {
            return false; // Record not found
        }

        //
        // Updates the record.
        //
        const existingRecord = records[recordIndex];
        const updatedRecord = { ...existingRecord, ...updates, id };
        records[recordIndex] = updatedRecord;

        //
        // Writes the updated records back to the file.
        //
        await this.saveShardFile(shardFilePath, records);

        return true;
    }

    //
    // Deletes a record.
    //
    async delete(id: string): Promise<boolean> {

        //
        // Reads the shard.
        //
        const shardId = this.generateShardId(id);
        const shardFilePath = `${this.directory}/${shardId}`;

        let records = this.shardCache.get(shardId);
        if (records === undefined) {
            records = await this.loadRecords(shardFilePath); //TODO: Could be an expensive operation. We don't need to load all records into memory.
            this.shardCache.set(shardId, records);
        }

        //
        // Find the record to delete.
        //
        const recordIndex = records.findIndex(e => e._id === id); //todo: Be good to do a fast lookup.
        if (recordIndex < 0) {
            return false; // Record not found
        }

        //
        // Delete the record.
        //
        records.splice(recordIndex, 1);

        //
        // Saves the updated file (or deletes if empty).
        //
        await this.saveShardFile(shardFilePath, records);

        return true;
    }
}