import { MockStorage } from 'storage';
import fs from 'fs';
import path from 'path';
import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
import { BsonDatabase } from 'bdb';
import type { IBsonCollection } from 'bdb';
import { RandomUuidGenerator } from 'utils';

describe('Collection duplicate document tests', () => {
    let db: BsonDatabase;
    let collection: IBsonCollection<any>;
    let tempDir: string;
    
    beforeEach(async () => {
        // Setup a temporary directory for testing
        tempDir = path.join(__dirname, 'temp-test-db-' + Date.now());
        fs.mkdirSync(tempDir, { recursive: true });
        
        // Create a database with a mock storage
        const storage = new MockStorage();
        db = new BsonDatabase({ 
            storage,
            uuidGenerator: new RandomUuidGenerator(),
        });
        
        // Create a test collection
        collection = db.collection('testCollection');
    });
    
    afterEach(async () => {
        if (fs.existsSync(tempDir)) {
            fs.rmSync(tempDir, { recursive: true, force: true });
        }
    });
    
    test('should throw error when inserting document with duplicate ID', async () => {
        // Create a test document with a specific ID
        const testDoc = {
            _id: '12345678-1234-1234-1234-123456789012',
            name: 'Test Document',
            value: 42
        };
        
        // First insert should succeed
        await collection.insertOne(testDoc);
        
        // Second insert with same ID should throw an error
        await expect(collection.insertOne(testDoc)).rejects.toThrow(
            `Document with ID ${testDoc._id} already exists`
        );
    });
    
    test('should allow inserting documents with different IDs', async () => {
        // Create two test documents with different IDs
        const testDoc1 = {
            _id: '12345678-1234-1234-1234-123456789012',
            name: 'Test Document 1',
            value: 42
        };
        
        const testDoc2 = {
            _id: '87654321-4321-4321-4321-210987654321',
            name: 'Test Document 2',
            value: 100
        };
        
        // Both inserts should succeed
        await collection.insertOne(testDoc1);
        await collection.insertOne(testDoc2);
        
        // Verify both documents exist
        const doc1 = await collection.getOne(testDoc1._id);
        const doc2 = await collection.getOne(testDoc2._id);
        
        expect(doc1).toBeDefined();
        expect(doc1?.name).toBe('Test Document 1');
        
        expect(doc2).toBeDefined();
        expect(doc2?.name).toBe('Test Document 2');
    });
    
    test('should generate ID if not provided and not allow duplicate inserts', async () => {
        // Create a test document without an ID
        const testDoc = {
            name: 'Test Document',
            value: 42
        };
        
        // First insert should succeed and assign an ID
        await collection.insertOne(testDoc);
        
        // Get the inserted document's ID
        const allRecords = await collection.getAll();
        const insertedDoc = allRecords.records[0];
        const generatedId = insertedDoc._id;
        
        // Create a new document with the same generated ID
        const duplicateDoc = {
            _id: generatedId,
            name: 'Duplicate Document',
            value: 100
        };
        
        // Inserting with the same ID should throw an error
        await expect(collection.insertOne(duplicateDoc)).rejects.toThrow(
            `Document with ID ${generatedId} already exists`
        );
    });
});