//
// Unit tests for SortIndex deferred-write behaviour (commit/flush/onDirty).
//

import { MockStorage } from 'storage';
import { RandomUuidGenerator } from 'utils';
import { IRecord, toInternal } from '../lib/collection';
import { ISortIndexRecord, SortIndex } from '../lib/sort-index';
import { MockCollection } from './mock-collection';

interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    category: string;
}

describe('SortIndex (deferred writes)', () => {
    let storage: MockStorage;
    let sortIndex: SortIndex;
    const testRecords: TestRecord[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Record 1', score: 85, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Record 2', score: 72, category: 'B' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Record 3', score: 90, category: 'A' },
    ];

    function makeSortIndex(onDirty?: () => void): SortIndex {
        return new SortIndex(
            storage,
            'db',
            'test_collection',
            'score',
            'asc',
            new RandomUuidGenerator(),
            undefined,
            onDirty,
        );
    }

    beforeEach(() => {
        storage = new MockStorage();
        sortIndex = makeSortIndex();
    });

    async function getAllRecords(index: SortIndex): Promise<ISortIndexRecord[]> {
        const allRecords: ISortIndexRecord[] = [];
        let currentPage = await index.getPage('');
        allRecords.push(...currentPage.records);
        while (currentPage.nextPageId) {
            currentPage = await index.getPage(currentPage.nextPageId);
            allRecords.push(...currentPage.records);
        }
        return allRecords;
    }

    test('addRecord then commit persists the record', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174006',
            name: 'Record 6',
            score: 80,
            category: 'A'
        };
        await sortIndex.addRecord(toInternal<TestRecord>(newRecord, 1000));
        await sortIndex.commit();

        const found = await sortIndex.findByValue(80);
        expect(found.length).toBe(1);
        expect(found[0].name).toBe('Record 6');
    });

    test('addRecord then commit persists all records', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174010',
            name: 'Batch 1',
            score: 60,
            category: 'A'
        }, 1000));
        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174011',
            name: 'Batch 2',
            score: 95,
            category: 'B'
        }, 1000));
        await sortIndex.commit();

        const all = await getAllRecords(sortIndex);
        expect(all.length).toBe(5);
        const scores = all.map((record: ISortIndexRecord) => record.score);
        expect(scores).toContain(60);
        expect(scores).toContain(95);
        expect(await sortIndex.findByValue(60).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
        expect(await sortIndex.findByValue(95).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
    });

    test('updateRecord then commit persists update', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        const updated: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174001',
            name: 'Record 1 Updated',
            score: 50,
            category: 'A'
        };
        await sortIndex.updateRecord(
            toInternal<TestRecord>(updated, 1000),
            toInternal<TestRecord>(testRecords[0], 1000)
        );
        await sortIndex.commit();

        const at50 = await sortIndex.findByValue(50);
        expect(at50.length).toBe(1);
        expect(at50[0].name).toBe('Record 1 Updated');
        const at85 = await sortIndex.findByValue(85);
        expect(at85.length).toBe(0);
    });

    test('deleteRecord then commit persists delete', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        await sortIndex.deleteRecord(
            '123e4567-e89b-12d3-a456-426614174002',
            toInternal<TestRecord>(testRecords[1], 1000)
        );
        await sortIndex.commit();

        const all = await getAllRecords(sortIndex);
        expect(all.length).toBe(2);
        expect(all.find(record => record._id === '123e4567-e89b-12d3-a456-426614174002')).toBeUndefined();
    });

    test('mix of add, update, delete then commit', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174020',
            name: 'New',
            score: 88,
            category: 'A'
        }, 1000));
        await sortIndex.updateRecord(
            toInternal<TestRecord>({ ...testRecords[0], score: 70 }, 1000),
            toInternal<TestRecord>(testRecords[0], 1000)
        );
        await sortIndex.deleteRecord(
            testRecords[2]._id,
            toInternal<TestRecord>(testRecords[2], 1000)
        );
        await sortIndex.commit();

        const all = await getAllRecords(sortIndex);
        expect(all.length).toBe(3);
        expect(await sortIndex.findByValue(88).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
        expect(await sortIndex.findByValue(70).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
        expect(await sortIndex.findByValue(90).then((records: ISortIndexRecord[]) => records.length)).toBe(0);
    });

    test('commit when idle is no-op', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await expect(sortIndex.commit()).resolves.toBeUndefined();
    });

    test('multiple commit cycles', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);

        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: 'id-a',
            name: 'A',
            score: 1,
            category: 'X'
        }, 1000));
        await sortIndex.commit();

        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: 'id-b',
            name: 'B',
            score: 2,
            category: 'X'
        }, 1000));
        await sortIndex.commit();

        expect(await sortIndex.findByValue(1).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
        expect(await sortIndex.findByValue(2).then((records: ISortIndexRecord[]) => records.length)).toBe(1);
        const all = await getAllRecords(sortIndex);
        expect(all.length).toBe(5);
    });

    test('commit() keeps leafCache populated', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        // After build+commit, leafCache should be populated so getPage works without re-reading disk
        const page = await sortIndex.getPage();
        expect(page.records.length).toBeGreaterThan(0);
    });

    test('flush() clears leafCache', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await sortIndex.flush();
        // After flush, should still be able to getPage (loads from disk)
        await sortIndex.load();
        const page = await sortIndex.getPage();
        expect(page.records.length).toBeGreaterThan(0);
    });

    test('flush() throws when dirtyLeaves is not empty', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174099',
            name: 'New',
            score: 55,
            category: 'Z'
        }, 1000));
        expect(() => sortIndex.flush()).toThrow("can't flush");
    });

    test('flush() throws when deletedLeaves is not empty', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await sortIndex.deleteRecord(
            testRecords[0]._id,
            toInternal<TestRecord>(testRecords[0], 1000)
        );
        expect(() => sortIndex.flush()).toThrow("can't flush");
    });

    test('hasDirtyData() returns false on a fresh index', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        expect(sortIndex.dirty()).toBe(false);
    });

    test('hasDirtyData() returns true after addRecord', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174099',
            name: 'New',
            score: 55,
            category: 'Z'
        }, 1000));
        expect(sortIndex.dirty()).toBe(true);
    });

    test('hasDirtyData() returns false after commit()', async () => {
        const collection = new MockCollection<TestRecord>(testRecords);
        await sortIndex.build(collection);
        await sortIndex.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174099',
            name: 'New',
            score: 55,
            category: 'Z'
        }, 1000));
        await sortIndex.commit();
        expect(sortIndex.dirty()).toBe(false);
    });

    test('onDirty callback fires on first dirty transition', async () => {
        let callCount = 0;
        const index = makeSortIndex(() => { callCount++; });
        const collection = new MockCollection<TestRecord>(testRecords);
        await index.build(collection);
        callCount = 0; // reset — build calls commit internally

        await index.addRecord(toInternal<TestRecord>({
            _id: '123e4567-e89b-12d3-a456-426614174099',
            name: 'New',
            score: 55,
            category: 'Z'
        }, 1000));
        expect(callCount).toBe(1);
    });

    test('onDirty callback does not fire again until commit', async () => {
        let callCount = 0;
        const index = makeSortIndex(() => { callCount++; });
        const collection = new MockCollection<TestRecord>(testRecords);
        await index.build(collection);
        callCount = 0;

        await index.addRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174099', name: 'New', score: 55, category: 'Z' }, 1000));
        await index.addRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174098', name: 'New2', score: 56, category: 'Z' }, 1000));
        expect(callCount).toBe(1);
    });

    test('onDirty callback fires again after commit then addRecord', async () => {
        let callCount = 0;
        const index = makeSortIndex(() => { callCount++; });
        const collection = new MockCollection<TestRecord>(testRecords);
        await index.build(collection);
        callCount = 0;

        await index.addRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174099', name: 'New', score: 55, category: 'Z' }, 1000));
        await index.commit();
        callCount = 0;

        await index.addRecord(toInternal<TestRecord>({ _id: '123e4567-e89b-12d3-a456-426614174098', name: 'New2', score: 56, category: 'Z' }, 1000));
        expect(callCount).toBe(1);
    });
});
