import { MockStorage } from 'storage';
import { BsonCollection, type IRecord, type IInternalRecord } from '../lib/collection';
import { MockTimestampProvider, RandomUuidGenerator } from 'utils';

// Test interfaces
interface TestRecord extends IRecord {
    _id: string;
    name: string;
    email?: string;
    age?: number;
    address?: {
        street: string;
        city: string;
        zip?: string;
        country?: {
            code: string;
            name: string;
        };
    };
}

// Helper function to get internal record with metadata
//TODO: Might want to have something similar to getOne() that can get the internal version of the record.
//      Or just have all functions return the internal version of the record.
async function getInternalRecord(collection: BsonCollection<TestRecord>, id: string): Promise<IInternalRecord | undefined> {
    for await (const record of collection.iterateRecords()) {
        if (record._id === id) {
            return record;
        }
    }
    return undefined;
}

describe('Collection Metadata and Timestamps', () => {
    let storage: MockStorage;
    let collection: BsonCollection<TestRecord>;
    let timestampProvider: MockTimestampProvider;
    beforeEach(() => {
        storage = new MockStorage();
        timestampProvider = new MockTimestampProvider(1000);
        collection = new BsonCollection<TestRecord>('test', {
            storage,
            directory: 'test',
            uuidGenerator: new RandomUuidGenerator(),
            timestampProvider,
            numShards: 10
        });
    });

    test('inserting puts a timestamp on the entire record', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174001';
        const timestamp = 1000;
        timestampProvider.setTimestamp(timestamp);
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(timestamp);
        expect(internal!.metadata.fields).toBeUndefined();
    });

    test('updating a root field sets the timestamp for that field but not others', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174002';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const updateTimestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        await collection.updateOne(id, { name: 'Jane Doe' }, { timestamp: updateTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(insertTimestamp);        
        expect(internal!.metadata.fields).toBeDefined();
        
        const nameMeta = internal!.metadata.fields!.name;
        expect(nameMeta).toBeDefined();
        expect((nameMeta).timestamp).toBe(updateTimestamp);
        
        // Other fields should not have individual timestamps (they inherit from parent).
        expect(internal!.metadata.fields!.email).toBeUndefined();
        expect(internal!.metadata.fields!.age).toBeUndefined();
    });

    test('updating a nested field sets the timestamp for the nested field but not others', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174003';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const updateTimestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            address: {
                street: '123 Main St',
                city: 'New York',
                zip: '10001',
            },
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        await collection.updateOne(id, { 
            address: { 
                street: '456 Oak Ave',
                city: 'New York', // Unchanged
                // zip not set
            },
        }, { timestamp: updateTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(insertTimestamp);
        expect(internal!.metadata.fields).toBeDefined();
        const addressMeta = internal!.metadata.fields!.address;
        expect(addressMeta).toBeDefined();
        const addressObjMeta = addressMeta!;
        expect(addressObjMeta.fields).toBeDefined();
        const streetMeta = addressObjMeta.fields!.street;
        expect(streetMeta).toBeDefined();
        expect((streetMeta).timestamp).toBe(updateTimestamp);
        
        // City and zip should not have individual timestamp (unchanged, inherits from address).
        expect(addressObjMeta.fields!.city).toBeUndefined();
        expect(addressObjMeta.fields!.zip).toBeUndefined();
    });

    test('replacing a record sets one timestamp for the entire record', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174004';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const replaceTimestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        
        const replacement: TestRecord = {
            _id: id,
            name: 'Jane Doe',
            email: 'jane@example.com',
            age: 25
        };
        
        await collection.replaceOne(id, replacement, { timestamp: replaceTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(replaceTimestamp);
        expect(internal!.metadata.fields).toBeUndefined();
    });

    test('updating multiple fields at once updates their timestamps', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174005';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const updateTimestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        await collection.updateOne(id, { 
            name: 'Jane Doe',
            age: 31
        }, { timestamp: updateTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(insertTimestamp);
        expect(internal!.metadata.fields).toBeDefined();
        const nameMeta = internal!.metadata.fields!.name;
        expect(nameMeta).toBeDefined();
        expect((nameMeta).timestamp).toBe(updateTimestamp);
        const ageMeta = internal!.metadata.fields!.age;
        expect(ageMeta).toBeDefined();
        expect((ageMeta).timestamp).toBe(updateTimestamp);

        // Email should not have individual timestamp (unchanged).
        expect(internal!.metadata.fields!.email).toBeUndefined();
    });

    test('updating a single field multiple times updates its timestamp each time', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174006';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const update1Timestamp = timestampProvider.now();
        timestampProvider.advance(100);
        const update2Timestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        await collection.updateOne(id, { name: 'Jane Doe' }, { timestamp: update1Timestamp });
        await collection.updateOne(id, { name: 'Bob Smith' }, { timestamp: update2Timestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.fields).toBeDefined();
        const nameMeta = internal!.metadata.fields!.name;
        expect(nameMeta).toBeDefined();
        expect((nameMeta).timestamp).toBe(update2Timestamp); // Latest timestamp
        expect((nameMeta).timestamp).not.toBe(update1Timestamp);
    });

    test('deleting a field with newer timestamp preserves metadata entry', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174008';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            email: 'john@example.com',
            age: 30
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });

        timestampProvider.advance(100);
        const updateTimestamp = timestampProvider.now();
        await collection.updateOne(id, { name: 'Jane Doe' }, { timestamp: updateTimestamp });
        
        // Verify name has metadata
        let internal = await getInternalRecord(collection, id);
        const nameMeta1 = internal!.metadata.fields!.name;
        expect(nameMeta1).toBeDefined();
        expect((nameMeta1).timestamp).toBe(updateTimestamp);
        
        // Delete the name field with a newer timestamp
        timestampProvider.advance(100);
        const deletionTimestamp = timestampProvider.now();
        await collection.updateOne(id, { name: undefined }, { timestamp: deletionTimestamp });
        
        internal = await getInternalRecord(collection, id);

        // After deletion, the field should have metadata with the deletion timestamp
        expect(internal!.metadata.fields).toBeDefined();
        const nameMeta2 = internal!.metadata.fields!.name;
        expect(nameMeta2).toBeDefined();
        expect((nameMeta2).timestamp).toBe(deletionTimestamp);
        // The field should be undefined in the fields object
        expect(internal!.fields.name).toBeUndefined();
    });

    test('updating nested object with same timestamp as parent omits nested metadata', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174009';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            address: {
                street: '123 Main St',
                city: 'New York'
            }
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        
        // Update the entire address with the same timestamp
        await collection.updateOne(id, {
            address: {
                street: '456 Oak Ave',
                city: 'Boston'
            }
        }, { timestamp: insertTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(insertTimestamp);

        // Since timestamp is same as parent, no fields metadata should be created
        expect(internal!.metadata.fields).toBeUndefined();
    });

    test('deeply nested fields track timestamps correctly', async () => {
        const id = '123e4567-e89b-12d3-a456-42661417400a';
        const insertTimestamp = 1000;
        timestampProvider.setTimestamp(insertTimestamp);
        timestampProvider.advance(100);
        const updateTimestamp = timestampProvider.now();
        
        const record: TestRecord = {
            _id: id,
            name: 'John Doe',
            address: {
                street: '123 Main St',
                city: 'New York',
                country: {
                    code: 'US',
                    name: 'United States'
                }
            }
        };
        
        await collection.insertOne(record, { timestamp: insertTimestamp });
        await collection.updateOne(id, {
            address: {
                ...record.address!, //fio: don't want to repeat this!
                country: {
                    code: 'CA',
                    name: 'Canada'
                }
            }
        }, { timestamp: updateTimestamp });
        
        const internal = await getInternalRecord(collection, id);
        expect(internal).toBeDefined();
        expect(internal!.metadata.timestamp).toBe(insertTimestamp);
        
        const addressMeta = internal!.metadata.fields!.address;
        expect(addressMeta).toBeDefined();
        // address should be ObjectMetadata (nested object)
        const addressObjMeta = addressMeta!;
        const countryMeta = addressObjMeta.fields!.country;
        expect(countryMeta).toBeDefined();
        // country should be ObjectMetadata (nested object)
        
        // Street and city should not have individual timestamps (unchanged).
        expect(addressObjMeta.fields!.street).toBeUndefined();
        expect(addressObjMeta.fields!.city).toBeUndefined();
    });
});
