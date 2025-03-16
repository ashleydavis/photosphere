import crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from './storage';
import { retry } from 'utils';

interface DatabaseOptions {
    storage: IStorage;
    directory: string;
    maxRecordsPerFile: number;
    saveOptions?: {
        debounceTime: number; // Time in ms to wait before saving changes
        maxPendingWrites: number; // Force save after this many pending writes
    };
}

interface Record {
    _id: string;
    [key: string]: any;
}

// File structure will include an index section and data section
interface BsonFileHeader {
    version: number;        // File format version
    recordCount: number;    // Number of records in the file
    indexOffset: number;    // Offset to the record index
    lastModified: number;   // Timestamp of last modification
    checksumHeader: string; // Checksum of header fields
    checksumData: string;   // Checksum of data section
    checksumIndex: string;  // Checksum of index section
}

interface RecordEntry {
    id: string;            // Record ID
    offset: number;        // Offset in the data section
    length: number;        // Length of the record data
}

export class BsonDatabase {
    private storage: IStorage;
    private directory: string;
    private maxRecordsPerFile: number;

    // Maps file names to record IDs contained in the file
    private fileMap: Map<string, Set<string>> = new Map(); //todo: this is the shard map? really needed?

    // For debounced saving
    private pendingWrites: Map<string, Set<Record>> = new Map(); // File path -> Records to write
    private pendingDeletes: Set<string> = new Set(); // Files to delete
    private saveTimers: Map<string, NodeJS.Timeout> = new Map(); // File path -> Timer

    // Map to keep track of which files have been loaded
    private loadedFiles: Set<string> = new Set(); //todo: needed?

    constructor(options: DatabaseOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.maxRecordsPerFile = options.maxRecordsPerFile || 1000;
    }

    async initialize(): Promise<void> {
        // Load existing database metadata (but not file contents)
        await this.loadDatabaseState();
    }

    async shutdown(): Promise<void> {
        // Flush any pending writes before shutdown
        await this.flushPendingWrites();
    }

    private async loadDatabaseState(): Promise<void> {
        // Get all files in the directory
        const result = await this.storage.listFiles(this.directory, 1000);
        const dataFiles = (result.names || []).filter(file => file.endsWith('.bson'));

        // Just build the initial file map without loading all content
        for (const file of dataFiles) {
            // Initialize an empty set for each file
            this.fileMap.set(file, new Set<string>());

            // Read just the header and record index to populate the file map
            await this.loadFileIndex(file);
        }

        console.log(`Database initialized with ${dataFiles.length} data files (lazy loading enabled)`);
    }

    private async loadFileIndex(fileName: string): Promise<void> { //todo: needed?
        const filePath = this.makePath(fileName);

        try {
            // Read the file content
            const buffer = await this.storage.read(filePath);

            if (!buffer || buffer.length === 0) {
                // Empty file, nothing to load
                return;
            }

            // Parse the header
            const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

            // Now read the record index
            if (header.indexOffset > 0 && header.recordCount > 0 && header.indexOffset < buffer.length) {
                // Parse the record index
                const indexData = buffer.subarray(header.indexOffset);
                const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

                // Add all record IDs to the file map
                const recordIds = this.fileMap.get(fileName) || new Set<string>();
                for (const entry of recordIndex.entries) {
                    recordIds.add(entry.id);
                }

                this.fileMap.set(fileName, recordIds);
            }
        } 
        catch (error) {
            const exists = await this.storage.fileExists(filePath);
            if (!exists) {
                // File doesn't exist anymore
                this.fileMap.delete(fileName);
            } 
            else {
                console.error(`Failed to load file index for ${fileName}:`, error);
                throw error;
            }
        }
    }

    private async ensureFileLoaded(fileName: string): Promise<void> {
        // Skip if already loaded
        if (this.loadedFiles.has(fileName)) return;

        const filePath = this.makePath(fileName);

        // Check if file exists
        const exists = await this.storage.fileExists(filePath);
        if (!exists) {
            // File doesn't exist
            this.fileMap.delete(fileName);
            return;
        }

        // Read the file content
        const buffer = await this.storage.read(filePath);

        if (!buffer || buffer.length === 0) {
            // Empty file, nothing to load
            return;
        }

        // Parse the header
        let header: BsonFileHeader;
        try {
            header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

            // Verify header checksum
            const headerForChecksum = { ...header, checksumHeader: '' };
            const headerForChecksumBson = BSON.serialize(headerForChecksum);
            if (!this.verifyChecksum(headerForChecksumBson, header.checksumHeader)) {
                throw new Error('Header checksum verification failed, possible file corruption');
            }
        } 
        catch (error: any) {
            console.error(`Error parsing file header for ${fileName}: ${error.message}`);

            // Try to recover from backup
            const backupFiles = await this.findBackups(filePath);
            if (backupFiles.length > 0) {
                await this.recoverFromBackup(filePath, backupFiles[0].path);
                // Try again with the recovered file
                return this.ensureFileLoaded(fileName);
            }

            throw new Error(`Cannot load corrupted file ${fileName} and no valid backup found`);
        }

        // Get the index data
        const indexData = buffer.subarray(header.indexOffset);

        // Verify index checksum
        if (!this.verifyChecksum(indexData, header.checksumIndex)) {
            throw new Error('Index checksum verification failed, possible file corruption');
        }

        // Parse the record index
        const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

        // Verify data checksums and load records
        let isDataCorrupted = false;

        // Calculate checksum of all data
        const dataBuffer = buffer.subarray(BSON.serialize(header).length, header.indexOffset);
        if (!this.verifyChecksum(dataBuffer, header.checksumData)) {
            isDataCorrupted = true;
        }

        // Update file map with record IDs
        if (!this.fileMap.has(fileName)) {
            this.fileMap.set(fileName, new Set<string>());
        }

        const recordIds = this.fileMap.get(fileName)!;

        if (!isDataCorrupted) {
            // Process each record
            for (const entry of recordIndex.entries) {
                recordIds.add(entry.id);

                // Extract the record data
                const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
                try {
                    const record = BSON.deserialize(recordData) as Record;

                    // todo: read for no reason?

                } 
                catch (error: any) {
                    console.error(`Error parsing record ${entry.id}: ${error.message}`);
                    isDataCorrupted = true;
                    break;
                }
            }
        }

        if (isDataCorrupted) {
            console.error(`Data corruption detected in file ${fileName}`);

            // Try to recover from backup
            const backupFiles = await this.findBackups(filePath);
            if (backupFiles.length > 0) {
                await this.recoverFromBackup(filePath, backupFiles[0].path);
                // Try again with the recovered file
                this.loadedFiles.delete(fileName); // Make sure it's not marked as loaded
                return this.ensureFileLoaded(fileName);
            }

            console.warn(`Cannot recover corrupted file ${fileName}, will rebuild from cache if possible`);

            // Even with corruption, we can still use the record IDs that we have
            // Other operations will attempt to load the actual data and handle errors
        }

        // Mark as loaded
        this.loadedFiles.add(fileName);
   }

    // Find all backups for a file
    private async findBackups(filePath: string): Promise<{ path: string, timestamp: number }[]> {
        const directory = this.directory;
        const filename = filePath.split('/').pop() || '';

        // Find all backup files for this file
        const result = await this.storage.listFiles(directory, 1000);
        const files = result.names || [];

        const backupPattern = new RegExp(`^${filename}\\.backup_(\\d+)$`);

        return files
            .map(file => {
                const match = file.match(backupPattern);
                if (match) {
                    return {
                        path: this.makePath(file),
                        timestamp: parseInt(match[1], 10)
                    };
                }
                return null;
            })
            .filter((item): item is { path: string, timestamp: number } => item !== null)
            .sort((a, b) => b.timestamp - a.timestamp); // Sort descending by timestamp (newest first)
    }

    // Function to load files in the background
    private async preloadFiles(limit: number = 5): Promise<void> {
        const files = [...this.fileMap.keys()].filter(file => !this.loadedFiles.has(file));

        // Load files in batches to avoid overloading memory
        const filesToLoad = files.slice(0, limit);

        for (const file of filesToLoad) {
            await this.ensureFileLoaded(file);
        }
    }

    private generateShardId(recordId: string): string {
        // Use a hashing function to determine which shard a record belongs to
        const hash = crypto.createHash('md5').update(recordId).digest('hex');
        return `data_${hash.substring(0, 8)}.bson`;
    }

    // Calculate checksum for a buffer
    private calculateChecksum(buffer: Uint8Array): string {
        return crypto.createHash('sha256').update(buffer).digest('hex');
    }

    // Verify checksum to detect data corruption
    private verifyChecksum(buffer: Uint8Array, expectedChecksum: string): boolean {
        const actualChecksum = this.calculateChecksum(buffer);
        return actualChecksum === expectedChecksum;
    }

    // Helper to build paths with the correct directory
    private makePath(fileName: string): string {
        if (this.directory.endsWith('/')) {
            return `${this.directory}${fileName}`;
        }
        return `${this.directory}/${fileName}`;
    }

    // Create a backup of a file before modifying it
    private async createBackup(filePath: string): Promise<string> {
        // Only create backup if the file exists
        const exists = await this.storage.fileExists(filePath);
        if (!exists) {
            return ''; // File doesn't exist, no backup needed
        }

        // Create backup filename with timestamp
        const backupFilePath = `${filePath}.backup_${Date.now()}`;

        // Copy the file
        await this.storage.copyTo(filePath, backupFilePath);

        return backupFilePath;
    }

    // Recover from a corrupted file using the backup
    private async recoverFromBackup(filePath: string, backupFilePath: string): Promise<void> {
        if (!backupFilePath) {
            throw new Error(`No backup available for ${filePath}`);
        }

        try {
            await this.storage.copyTo(backupFilePath, filePath);
            console.log(`Recovered ${filePath} from backup ${backupFilePath}`);
        } 
        catch (error: any) {
            throw new Error(`Failed to recover from backup: ${error.message}`);
        }
    }

    private async saveFile(filePath: string, records: Record[]): Promise<void> {
        if (records.length === 0) {
            // Delete empty files
            const exists = await this.storage.fileExists(filePath);
            if (exists) {
                this.pendingDeletes.add(filePath);
                await this.scheduleSave(filePath);
            }
            return;
        }

        // Add to pending writes
        if (!this.pendingWrites.has(filePath)) {
            this.pendingWrites.set(filePath, new Set());
        }

        // Add all records to the pending writes for this file
        const fileRecords = this.pendingWrites.get(filePath)!;
        records.forEach(record => {
            fileRecords.add(record);
        });

        // Schedule the save
        await this.scheduleSave(filePath);
    }

    private async scheduleSave(filePath: string): Promise<void> {

        //
        // Immediate write:
        // 
        // await this.flushPendingWrites();

        // Clear any existing timer for this file
        if (this.saveTimers.has(filePath)) {
            clearTimeout(this.saveTimers.get(filePath)!);
        }

        // Schedule a debounced save
        const timer = setTimeout(() => {
            this.flushPendingWrites();
        }, 300);

        this.saveTimers.set(filePath, timer);
    }

    //
    // Flush writes yet to go out.
    //
    private async flushPendingWrites(): Promise<void> {
        // Clear all timers
        for (const timer of this.saveTimers.values()) {
            clearTimeout(timer);
        }
        this.saveTimers.clear();

        // Process all pending writes
        const writePromises: Promise<void>[] = [];

        for (const [filePath, recordsSet] of this.pendingWrites.entries()) {
            const records = Array.from(recordsSet);
            writePromises.push(this.writeBsonFile(filePath, records));
        }

        // Process all pending deletes
        for (const filePath of this.pendingDeletes) {
            writePromises.push(
                (async () => {
                    try {
                        // Create backup before deleting
                        await this.createBackup(filePath);
                        await this.storage.delete(filePath);
                    } 
                    catch (error) {
                        // Ignore error if file doesn't exist
                        console.error(`Failed to delete ${filePath}:`, error);
                    }
                })()
            );
        }

        // Wait for all operations to complete
        try {
            await Promise.all(writePromises);
        } 
        finally {
            // Clear pending operations
            this.pendingWrites.clear();
            this.pendingDeletes.clear();
        }
    }

    //
    // Writes a shard to disk.
    //
    private async writeBsonFile(filePath: string, records: Record[]): Promise<void> {

        // Create backup before modifying
        const backupFilePath = await this.createBackup(filePath);

        // Prepare data sections first so we can calculate checksums
        const recordBuffers: Uint8Array[] = [];
        const recordEntries: RecordEntry[] = [];

        // Temporary header without checksums
        const tempHeader: BsonFileHeader = {
            version: 1,
            recordCount: records.length,
            indexOffset: 0, // Will be updated later
            lastModified: Date.now(),
            checksumHeader: '', // Will be updated later
            checksumData: '',   // Will be updated later
            checksumIndex: ''   // Will be updated later
        };

        // Serialize header to get its size (will reserialize later with checksums)
        const tempHeaderBson = BSON.serialize(tempHeader);

        // Current offset (start after header)
        let currentOffset = tempHeaderBson.length;

        // Serialize each record
        for (const record of records) {
            const recordBson = BSON.serialize(record);
            recordBuffers.push(recordBson);

            // Add to record index
            recordEntries.push({
                id: record._id,
                offset: currentOffset,
                length: recordBson.length
            });

            // Update offset for next record
            currentOffset += recordBson.length;
        }

        // All records have been serialized, update index offset
        tempHeader.indexOffset = currentOffset;

        // Combine record buffers for data checksum
        const dataBuffer = Buffer.concat(recordBuffers);
        tempHeader.checksumData = this.calculateChecksum(dataBuffer);

        // Create index BSON
        const indexObject = { entries: recordEntries };
        const indexBson = BSON.serialize(indexObject);
        tempHeader.checksumIndex = this.calculateChecksum(indexBson);

        // Now create the final header with all checksums
        const headerObject = { ...tempHeader };

        // Calculate header checksum (excluding the checksumHeader field itself)
        const headerForChecksum = { ...headerObject, checksumHeader: '' };
        const headerForChecksumBson = BSON.serialize(headerForChecksum);
        headerObject.checksumHeader = this.calculateChecksum(headerForChecksumBson);

        // Serialize the final header
        const headerBson = BSON.serialize(headerObject);

        // Combine all buffers for the complete file
        const fileBuffer = Buffer.concat([
            headerBson,
            ...recordBuffers,
            indexBson
        ]);

        try {
            // Write file
            await this.storage.write(filePath, undefined, fileBuffer);

            const readBuffer = await retry(() => this.storage.read(filePath));
            if (!readBuffer) {
                throw new Error(`Verification failed (file not found)`);
            }

            // First verify the file sizes match
            if (readBuffer.length !== fileBuffer.length) {
                throw new Error(`Verification failed (size mismatch: ${readBuffer.length} vs ${fileBuffer.length})`);
            }

            // Then verify checksums
            const writtenHeaderChecksum = this.calculateChecksum(readBuffer.subarray(0, headerBson.length));
            const originalHeaderChecksum = this.calculateChecksum(headerBson);
            if (writtenHeaderChecksum !== originalHeaderChecksum) {
                throw new Error(`Verification failed (header checksum mismatch)`);
            }

            const writtenDataChecksum = this.calculateChecksum(readBuffer.subarray(headerBson.length, headerBson.length + dataBuffer.length));
            const originalDataChecksum = this.calculateChecksum(dataBuffer);
            if (writtenDataChecksum !== originalDataChecksum) {
                throw new Error(`Verification failed (data checksum mismatch)`);
            }

            const writtenIndexChecksum = this.calculateChecksum(readBuffer.subarray(headerBson.length + dataBuffer.length));
            const originalIndexChecksum = this.calculateChecksum(indexBson);
            if (writtenIndexChecksum !== originalIndexChecksum) {
                throw new Error(`Verification failed (index checksum mismatch)`);
            }
        } 
        catch (writeError: any) {
            console.error(`Write error: ${writeError.message}`);

            // If we have a backup, restore it
            if (backupFilePath) {
                await this.recoverFromBackup(filePath, backupFilePath);
            }

            throw writeError;
        }

        // After successful write, remove older backups (keep the latest one)
        // This can be done asynchronously, we don't need to wait for it
        this.cleanupOldBackups(filePath).catch(error => {
            console.warn(`Failed to clean up old backups for ${filePath}:`, error);
        });
    }

    // Cleanup old backup files
    private async cleanupOldBackups(filePath: string): Promise<void> {
        const directory = this.directory;
        const filename = filePath.split('/').pop() || '';

        // Find all backup files for this file
        const result = await this.storage.listFiles(directory, 1000);
        const files = result.names || [];
        const backupPattern = new RegExp(`^${filename}\\.backup_(\\d+)$`);

        const backups = files
            .filter(file => backupPattern.test(file))
            .map(file => {
                const match = file.match(backupPattern);
                return {
                    path: this.makePath(file),
                    timestamp: parseInt(match![1], 10)
                };
            })
            .sort((a, b) => b.timestamp - a.timestamp); // Sort descending by timestamp

        // Keep the most recent backup, delete others
        for (let i = 1; i < backups.length; i++) {
            await this.storage.delete(backups[i].path);
        }
    }

    //
    // Insert a new record into the database.
    //
    async insert(record: Record): Promise<void> {
        if (!record._id) {
            record._id = crypto.randomUUID();
        }

        // Determine which file to store the record in
        const shardId = this.generateShardId(record._id);
        const filePath = this.makePath(shardId);

        // Check if the file exists and read its content
        let records: Record[] = [];
        let fileExists = await this.storage.fileExists(filePath);

        if (fileExists) {
            // Ensure file is loaded
            if (!this.loadedFiles.has(shardId)) {
                await this.ensureFileLoaded(shardId);
            }

            // Read all records from the file
            const buffer = await this.storage.read(filePath);

            if (buffer && buffer.length > 0) {
                // Parse the header
                const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

                // Read the record index
                const indexData = buffer.subarray(header.indexOffset);
                const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

                // Read each record
                for (const entry of recordIndex.entries) {
                    const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
                    const existingRecord = BSON.deserialize(recordData) as Record;
                    records.push(existingRecord);
                }
            }
        }

        // Check if the file has reached its maximum capacity
        if (records.length >= this.maxRecordsPerFile) {
            // Create a new file with a unique name
            const timestamp = Date.now();
            const newShardId = `data_${timestamp}_${crypto.randomBytes(4).toString('hex')}.bson`;
            const newFilePath = this.makePath(newShardId);

            // Save the record to the new file
            await this.saveFile(newFilePath, [record]);

            // Update file map
            if (!this.fileMap.has(newShardId)) {
                this.fileMap.set(newShardId, new Set<string>());
            }
            this.fileMap.get(newShardId)!.add(record._id);
        } 
        else {
            // Add the record to the existing file
            records.push(record);
            await this.saveFile(filePath, records);

            // Update file map
            if (!this.fileMap.has(shardId)) {
                this.fileMap.set(shardId, new Set<string>());
            }
            this.fileMap.get(shardId)!.add(record._id);
        }        
    }

    async findById(id: string): Promise<Record | null> {
        // Find which file might contain the record
        let targetFile: string | null = null;

        // Try the expected file first (based on ID)
        const expectedFile = this.generateShardId(id);
        if (this.fileMap.has(expectedFile)) {
            // Check if the ID is in this file
            if (this.fileMap.get(expectedFile)!.has(id)) {
                targetFile = expectedFile;
            } 
            else {
                // Ensure file is loaded in case the ID map isn't complete
                await this.ensureFileLoaded(expectedFile);

                // Check again after loading
                if (this.fileMap.get(expectedFile)!.has(id)) {
                    targetFile = expectedFile;
                }
            }
        }

        // If not found in the expected file, search other loaded files
        if (!targetFile) {
            for (const [file, recordIds] of this.fileMap.entries()) {
                if (this.loadedFiles.has(file) && recordIds.has(id)) {
                    targetFile = file;
                    break;
                }
            }
        }

        // If still not found but not all files are loaded, load remaining files and check
        if (!targetFile) {
            // Load all remaining files
            const unloadedFiles = [...this.fileMap.keys()].filter(file => !this.loadedFiles.has(file));

            for (const file of unloadedFiles) {
                await this.ensureFileLoaded(file);

                if (this.fileMap.get(file)!.has(id)) {
                    targetFile = file;
                    break;
                }
            }
        }

        if (!targetFile) {
            return null; // Record not found
        }

        // Find and return the record from the file
        await this.ensureFileLoaded(targetFile);

        // Read the file to find the record
        const filePath = this.makePath(targetFile);
        const buffer = await this.storage.read(filePath);

        if (!buffer || buffer.length === 0) {
            return null; // Empty file
        }

        // Parse the header
        const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

        // Read the record index
        const indexData = buffer.subarray(header.indexOffset);
        const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

        // Find the entry for this ID
        const entry = recordIndex.entries.find(e => e.id === id);
        if (!entry) {
            return null; // Record not found
        }

        // Extract and parse the record
        const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
        const record = BSON.deserialize(recordData) as Record;

        return record;
    }

    async *iterateRecords(options?: { limit?: number; skip?: number }): AsyncGenerator<Record, void, unknown> {
        // This generator yields records one at a time without loading all into memory
        const limit = options?.limit || Number.MAX_SAFE_INTEGER;
        const skip = options?.skip || 0;

        let yielded = 0;
        let skipped = 0;

        // Iterate through all files
        for (const file of this.fileMap.keys()) {
            // Stop if we've reached the limit
            if (yielded >= limit) {
                break;
            }

            // Ensure the file is loaded
            await this.ensureFileLoaded(file);

            const filePath = this.makePath(file);

            // Skip if file no longer exists
            const exists = await this.storage.fileExists(filePath);
            if (!exists) {
                continue;
            }

            const buffer = await this.storage.read(filePath);

            if (!buffer || buffer.length === 0) continue;

            // Parse the header
            const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

            // Read the record index
            const indexData = buffer.subarray(header.indexOffset);
            const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

            // Process each record
            for (const entry of recordIndex.entries) {
                // Skip records if needed
                if (skipped < skip) {
                    skipped++;
                    continue;
                }

                const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
                const record = BSON.deserialize(recordData) as Record;

                // Yield this record
                yield record;
                yielded++;

                // Stop if we've reached the limit
                if (yielded >= limit) {
                    break;
                }
            }
        }

        // Start background preloading of more files for next time
        this.preloadFiles(5).catch(err => {
            console.error('Background file preloading failed:', err);
        });
    }

    async findAll(options?: { limit?: number; skip?: number }): Promise<Record[]> {
        const results: Record[] = [];

        // Use the generator to process records one by one
        for await (const record of this.iterateRecords(options)) {
            results.push(record);
        }

        return results;
    }

    async update(id: string, updates: Partial<Record>): Promise<boolean> {
        // Find which file contains the record
        const record = await this.findById(id);

        if (!record) {
            return false; // Record not found
        }

        // Find the file containing this record
        let targetFile: string | null = null;

        for (const [file, recordIds] of this.fileMap.entries()) {
            if (recordIds.has(id)) {
                targetFile = file;
                break;
            }
        }

        if (!targetFile) {
            return false; // Record not found (should not happen here)
        }

        // Ensure the file is loaded
        await this.ensureFileLoaded(targetFile);

        // Read the file
        const filePath = this.makePath(targetFile);
        const buffer = await this.storage.read(filePath);

        if (!buffer || buffer.length === 0) {
            return false; // Empty file
        }

        // Parse the header
        const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

        // Read the record index
        const indexData = buffer.subarray(header.indexOffset);
        const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

        // Load all records
        const records: Record[] = [];

        for (const entry of recordIndex.entries) {
            const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
            const existingRecord = BSON.deserialize(recordData) as Record;

            if (existingRecord._id === id) {
                // Apply updates
                const updatedRecord = { ...existingRecord, ...updates, id };
                records.push(updatedRecord);

            } 
            else {
                records.push(existingRecord);
            }
        }

        // Write the updated records back to the file (debounced)
        await this.saveFile(filePath, records);

        return true;
    }

    async delete(id: string): Promise<boolean> {
        // Find which file contains the record
        const record = await this.findById(id);

        if (!record) {
            return false; // Record not found
        }

        // Find the file containing this record
        let targetFile: string | null = null;

        for (const [file, recordIds] of this.fileMap.entries()) {
            if (recordIds.has(id)) {
                targetFile = file;
                break;
            }
        }

        if (!targetFile) {
            return false; // Record not found (should not happen here)
        }

        // Ensure the file is loaded
        await this.ensureFileLoaded(targetFile);

        // Read the file
        const filePath = this.makePath(targetFile);
        const buffer = await this.storage.read(filePath);

        if (!buffer || buffer.length === 0) {
            return false; // Empty file
        }

        // Parse the header
        const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

        // Read the record index
        const indexData = buffer.subarray(header.indexOffset);
        const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

        // Load all records except the one to delete
        const records: Record[] = [];

        for (const entry of recordIndex.entries) {
            const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
            const existingRecord = BSON.deserialize(recordData) as Record;

            if (existingRecord._id === id) {
                //todo: Why nothing here after cache removed?
            } 
            else {
                records.push(existingRecord);
            }
        }

        // Update file map
        this.fileMap.get(targetFile)!.delete(id);

        // Save the updated file (or delete if empty)
        await this.saveFile(filePath, records);

        return true;
    }

    async compact(): Promise<void> {
        // This method consolidates files to optimize storage
        // We'll only compact if there are multiple files with low record counts

        const files = [...this.fileMap.keys()];

        // Skip compaction if there aren't enough files
        if (files.length <= 1) {
            return;
        }

        // Get file stats to determine which files to compact
        const fileStats: { name: string; count: number }[] = [];

        for (const file of files) {
            // Ensure file is loaded
            await this.ensureFileLoaded(file);

            const count = this.fileMap.get(file)!.size;
            fileStats.push({ name: file, count });
        }

        // Sort by record count (ascending)
        fileStats.sort((a, b) => a.count - b.count);

        // Only compact if there are files with low record counts
        // (less than 50% of max capacity)
        const threshold = this.maxRecordsPerFile / 2;
        const filesToCompact = fileStats.filter(stat => stat.count < threshold);

        if (filesToCompact.length <= 1) {
            return; // Not enough files to compact
        }

        // Collect all records from files to compact
        const allRecords: Record[] = [];

        for (const { name } of filesToCompact) {
            const filePath = this.makePath(name);
            const buffer = await this.storage.read(filePath);

            if (!buffer || buffer.length === 0) continue;

            // Parse the header
            const header = BSON.deserialize(buffer.subarray(0, Math.min(1024, buffer.length))) as BsonFileHeader;

            // Read the record index
            const indexData = buffer.subarray(header.indexOffset);
            const recordIndex = BSON.deserialize(indexData) as { entries: RecordEntry[] };

            // Load all records
            for (const entry of recordIndex.entries) {
                const recordData = buffer.subarray(entry.offset, entry.offset + entry.length);
                const record = BSON.deserialize(recordData) as Record;
                allRecords.push(record);
            }
        }

        // Create new optimized files
        const optimizedFiles: string[] = [];
        let currentRecords: Record[] = [];
        let currentFile = `data_compact_${Date.now()}.bson`;
        let currentPath = this.makePath(currentFile);

        for (const record of allRecords) {
            currentRecords.push(record);

            if (currentRecords.length >= this.maxRecordsPerFile) {
                // Write full file
                await this.saveFile(currentPath, currentRecords);
                optimizedFiles.push(currentFile);

                // Start a new file
                currentRecords = [];
                currentFile = `data_compact_${Date.now()}_${optimizedFiles.length}.bson`;
                currentPath = this.makePath(currentFile);
            }
        }

        // Write any remaining records
        if (currentRecords.length > 0) {
            await this.saveFile(currentPath, currentRecords);
            optimizedFiles.push(currentFile);
        }

        // Update file map with the new files
        for (let i = 0; i < optimizedFiles.length; i++) {
            const fileName = optimizedFiles[i];

            // Load the new file
            await this.loadFileIndex(fileName);
        }

        // Delete the old files
        for (const { name } of filesToCompact) {
            const filePath = this.makePath(name);
            await this.storage.delete(filePath);
            this.fileMap.delete(name);
            this.loadedFiles.delete(name);
        }
    }
}