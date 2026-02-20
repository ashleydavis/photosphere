//
// Unit tests for BatchSortIndexManager.
//

import { MockStorage } from 'storage';
import { RandomUuidGenerator, TimestampProvider } from 'utils';
import { BsonCollection, type IRecord, toInternal } from '../lib/collection';
import { BatchSortIndexManager } from '../lib/batch-sort-index-manager';

interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
}

describe('BatchSortIndexManager', () => {
    let storage: MockStorage;
    let collection: BsonCollection<TestRecord>;
    const ts = 1000;

    beforeEach(() => {
        storage = new MockStorage();
        collection = new BsonCollection<TestRecord>('items', {
            storage,
            directory: 'data/items',
            uuidGenerator: new RandomUuidGenerator(),
            timestampProvider: new TimestampProvider(),
            numShards: 5
        });
    });

    test('startBatch with no indexes leaves manager empty', async () => {
        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        await manager.syncRecord(toInternal<TestRecord>({ _id: 'id-1', name: 'A', score: 10 }, ts), undefined);
        await manager.commitChanges();
        const indexes = await collection.listSortIndexes();
        expect(indexes.length).toBe(0);
    });

    test('startBatch then syncRecord (add) then commitChanges updates index', async () => {
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'First', score: 50 });
        await collection.ensureSortIndex('score', 'asc', 'number');

        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        const newRecord = toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Second', score: 30 }, ts);
        await manager.syncRecord(newRecord, undefined);
        await manager.commitChanges();

        const sorted = await collection.getSorted('score', 'asc');
        expect(sorted.records.length).toBe(2);
        expect(sorted.records[0].score).toBe(30);
        expect(sorted.records[1].score).toBe(50);
    });

    test('startBatch then syncRecord (update) then commitChanges updates index', async () => {
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'First', score: 50 });
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Second', score: 70 });
        await collection.ensureSortIndex('score', 'asc', 'number');

        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        const updated = toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'First Updated', score: 90 }, ts);
        const old = toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'First', score: 50 }, ts);
        await manager.syncRecord(updated, old);
        await manager.commitChanges();

        const sorted = await collection.getSorted('score', 'asc');
        expect(sorted.records.length).toBe(2);
        expect(sorted.records[0].score).toBe(70);
        expect(sorted.records[1].score).toBe(90);
        expect(sorted.records[1].name).toBe('First Updated');
    });

    test('startBatch then removeRecord then commitChanges removes from index', async () => {
        await collection.insertOne({ _id: '123e4567e89b12d3a456426614174001', name: 'First', score: 50 });
        await collection.insertOne({ _id: '123e4567e89b12d3a456426614174002', name: 'Second', score: 70 });
        await collection.ensureSortIndex('score', 'asc', 'number');

        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        const toDelete = toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'First', score: 50 }, ts);
        await manager.removeRecord('123e4567-e89b-12d3-a456-426614174001', toDelete);
        await manager.commitChanges();

        const sorted = await collection.getSorted('score', 'asc');
        expect(sorted.records.length).toBe(1);
        expect(sorted.records[0]._id).toBe('123e4567-e89b-12d3-a456-426614174002');
    });

    test('startBatch then mix of sync and remove then commitChanges', async () => {
        const idA = '123e4567-e89b-12d3-a456-42661417400a';
        const idB = '123e4567-e89b-12d3-a456-42661417400b';
        const idC = '123e4567-e89b-12d3-a456-42661417400c';
        const idD = '123e4567-e89b-12d3-a456-42661417400d';
        await collection.insertOne({ _id: idA, name: 'A', score: 10 });
        await collection.insertOne({ _id: idB, name: 'B', score: 20 });
        await collection.insertOne({ _id: idC, name: 'C', score: 30 });
        await collection.ensureSortIndex('score', 'asc', 'number');

        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        await manager.syncRecord(toInternal<TestRecord>({ _id: idD, name: 'D', score: 25 }, ts), undefined);
        await manager.syncRecord(
            toInternal<TestRecord>({ _id: idB, name: 'B Updated', score: 50 }, ts),
            toInternal<TestRecord>({ _id: idB, name: 'B', score: 20 }, ts)
        );
        await manager.removeRecord(idA, toInternal<TestRecord>({ _id: idA, name: 'A', score: 10 }, ts));
        await manager.commitChanges();

        const sorted = await collection.getSorted('score', 'asc');
        expect(sorted.records.length).toBe(3);
        const scores = sorted.records.map(r => r.score);
        expect(scores).toEqual([25, 30, 50]);
        expect(sorted.records.find(r => r._id === idD)?.name).toBe('D');
        expect(sorted.records.find(r => r._id === idB)?.name).toBe('B Updated');
    });

    test('updates all managed indexes (multiple indexes)', async () => {
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174010', name: 'X', score: 100 });
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174020', name: 'Y', score: 200 });
        await collection.ensureSortIndex('score', 'asc', 'number');
        await collection.ensureSortIndex('score', 'desc', 'number');

        const manager = new BatchSortIndexManager(collection);
        await manager.startBatch();
        await manager.syncRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174030', name: 'Z', score: 150 }, ts), undefined);
        await manager.commitChanges();

        const asc = await collection.getSorted('score', 'asc');
        const desc = await collection.getSorted('score', 'desc');
        expect(asc.records.length).toBe(3);
        expect(desc.records.length).toBe(3);
        expect(asc.records.map(r => r.score)).toEqual([100, 150, 200]);
        expect(desc.records.map(r => r.score)).toEqual([200, 150, 100]);
    });

    test('commitChanges without startBatch does not throw', async () => {
        const manager = new BatchSortIndexManager(collection);
        await expect(manager.commitChanges()).resolves.toBeUndefined();
    });

    test('multiple startBatch/commitChanges cycles', async () => {
        await collection.insertOne({ _id: '123e4567-e89b-12d3-a456-426614174001', name: 'A', score: 1 });
        await collection.ensureSortIndex('score', 'asc', 'number');

        const manager = new BatchSortIndexManager(collection);

        await manager.startBatch();
        await manager.syncRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174002', name: 'B', score: 2 }, ts), undefined);
        await manager.commitChanges();

        await manager.startBatch();
        await manager.syncRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174003', name: 'C', score: 3 }, ts), undefined);
        await manager.commitChanges();

        const sorted = await collection.getSorted('score', 'asc');
        expect(sorted.records.length).toBe(3);
        expect(sorted.records.map(r => r.score)).toEqual([1, 2, 3]);
    });
});
