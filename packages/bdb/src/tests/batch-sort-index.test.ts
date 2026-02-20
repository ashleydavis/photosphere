//
// Unit tests for BatchSortIndex (batch variant of SortIndex with commitChanges to flush).
//

import { MockStorage } from 'storage';
import { RandomUuidGenerator } from 'utils';
import { IRecord, toInternal } from '../lib/collection';
import { ISortedIndexEntry } from '../lib/sort-index';
import { BatchSortIndex } from '../lib/batch-sort-index';
import { MockCollection } from './mock-collection';

interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    category: string;
}

describe('BatchSortIndex', () => {
    let storage: MockStorage;
    let batchIndex: BatchSortIndex;
    const testRecords: TestRecord[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Record 1', score: 85, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Record 2', score: 72, category: 'B' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Record 3', score: 90, category: 'A' },
    ];

    beforeEach(() => {
        storage = new MockStorage();
        batchIndex = new BatchSortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 2,
            uuidGenerator: new RandomUuidGenerator()
        });
    });

    async function getAllRecords(index: BatchSortIndex): Promise<ISortedIndexEntry[]> {
        const allRecords: ISortedIndexEntry[] = [];
        let currentPage = await index.getPage('');
        allRecords.push(...currentPage.records);
        while (currentPage.nextPageId) {
            currentPage = await index.getPage(currentPage.nextPageId);
            allRecords.push(...currentPage.records);
        }
        return allRecords;
    }

    test('addRecord then commitChanges persists the record (batch-only)', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174006',
            name: 'Record 6',
            score: 80,
            category: 'A'
        };
        await batchIndex.addRecord(toInternal<TestRecord>(newRecord, 1000));
        await batchIndex.commitChanges();

        const found = await batchIndex.findByValue(80);
        expect(found.length).toBe(1);
        expect(found[0].fields.name).toBe('Record 6');
    });

    test('addRecord then commitChanges persists all records', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        await batchIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174010',
            name: 'Batch 1',
            score: 60,
            category: 'A'
        }, 1000));
        await batchIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174011',
            name: 'Batch 2',
            score: 95,
            category: 'B'
        }, 1000));
        await batchIndex.commitChanges();

        const all = await getAllRecords(batchIndex);
        expect(all.length).toBe(5);
        const scores = all.map(r => r.fields.score);
        expect(scores).toContain(60);
        expect(scores).toContain(95);
        expect(await batchIndex.findByValue(60).then(r => r.length)).toBe(1);
        expect(await batchIndex.findByValue(95).then(r => r.length)).toBe(1);
    });

    test('updateRecord then commitChanges persists update', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        const updated: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174001',
            name: 'Record 1 Updated',
            score: 50,
            category: 'A'
        };
        await batchIndex.updateRecord(
            toInternal<TestRecord>(updated, 1000),
            toInternal<TestRecord>(testRecords[0], 1000)
        );
        await batchIndex.commitChanges();

        const at50 = await batchIndex.findByValue(50);
        expect(at50.length).toBe(1);
        expect(at50[0].fields.name).toBe('Record 1 Updated');
        const at85 = await batchIndex.findByValue(85);
        expect(at85.length).toBe(0);
    });

    test('deleteRecord then commitChanges persists delete', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        await batchIndex.deleteRecord(
            '123e4567-e89b-12d3-a456-426614174002',
            toInternal<TestRecord>(testRecords[1], 1000)
        );
        await batchIndex.commitChanges();

        const all = await getAllRecords(batchIndex);
        expect(all.length).toBe(2);
        expect(all.find(r => r._id === '123e4567-e89b-12d3-a456-426614174002')).toBeUndefined();
    });

    test('mix of add, update, delete then commitChanges', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        await batchIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174020',
            name: 'New',
            score: 88,
            category: 'A'
        }, 1000));
        await batchIndex.updateRecord(
            toInternal<TestRecord>({ ...testRecords[0], score: 70 }, 1000),
            toInternal<TestRecord>(testRecords[0], 1000)
        );
        await batchIndex.deleteRecord(
            testRecords[2]._id,
            toInternal<TestRecord>(testRecords[2], 1000)
        );
        await batchIndex.commitChanges();

        const all = await getAllRecords(batchIndex);
        expect(all.length).toBe(3);
        expect(await batchIndex.findByValue(88).then(r => r.length)).toBe(1);
        expect(await batchIndex.findByValue(70).then(r => r.length)).toBe(1);
        expect(await batchIndex.findByValue(90).then(r => r.length)).toBe(0);
    });

    test('commitChanges when idle is no-op', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);
        await expect(batchIndex.commitChanges()).resolves.toBeUndefined();
    });

    test('multiple commitChanges cycles', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await batchIndex.build(collection);

        await batchIndex.addRecord(toInternal<TestRecord>({
            _id: 'id-a',
            name: 'A',
            score: 1,
            category: 'X'
        }, 1000));
        await batchIndex.commitChanges();

        await batchIndex.addRecord(toInternal<TestRecord>({
            _id: 'id-b',
            name: 'B',
            score: 2,
            category: 'X'
        }, 1000));
        await batchIndex.commitChanges();

        expect(await batchIndex.findByValue(1).then(r => r.length)).toBe(1);
        expect(await batchIndex.findByValue(2).then(r => r.length)).toBe(1);
        const all = await getAllRecords(batchIndex);
        expect(all.length).toBe(5);
    });
});
