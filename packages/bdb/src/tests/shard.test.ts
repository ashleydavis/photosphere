import { BsonShard, getRecordKey, type IInternalRecord } from '../lib/shard';
import { MockStorage } from 'storage';
import { RandomUuidGenerator } from 'utils';

const testBsonDbPath = '';
const testCollectionName = 'test';
const testUuidGenerator = new RandomUuidGenerator();

function newTestShard(shardId: string, storage?: MockStorage): BsonShard {
    return new BsonShard(shardId, storage ?? new MockStorage(), testBsonDbPath, testCollectionName, testUuidGenerator);
}

function makeRecord(id: string, name: string): IInternalRecord {
    return { _id: id, fields: { name }, metadata: {} };
}

const recordId1 = '123e4567-e89b-12d3-a456-426614174000';
const recordId2 = 'aabbccdd-1122-3344-5566-778899aabbcc';
const recordId3 = '00000000-0000-0000-0000-000000000001';

// ─── normalizeShardRecordId ────────────────────────────────────────────────

test('normalizeShardRecordId strips dashes and returns 32-char hex', () => {
    const result = getRecordKey(recordId1);
    expect(result).toBe('123e4567e89b12d3a456426614174000');
    expect(result.length).toBe(32);
});

test('normalizeShardRecordId accepts already-normalized id', () => {
    const result = getRecordKey('123e4567e89b12d3a456426614174000');
    expect(result).toBe('123e4567e89b12d3a456426614174000');
});

test('normalizeShardRecordId throws for an invalid id', () => {
    expect(() => getRecordKey('not-a-uuid')).toThrow();
});

// ─── dirty / clean flags ───────────────────────────────────────────────────

test('BsonShard markDirty sets dirty flag', () => {
    const shard = newTestShard('s1');
    expect(shard.dirty()).toBe(false);
    shard.markDirty();
    expect(shard.dirty()).toBe(true);
});

test('BsonShard markClean clears dirty flag', () => {
    const shard = newTestShard('s1');
    shard.markDirty();
    shard.markClean();
    expect(shard.dirty()).toBe(false);
});

// ─── load ─────────────────────────────────────────────────────────────────

test('BsonShard load with missing file leaves empty records map', async () => {
    const shard = newTestShard('s1');
    await shard.load();
    expect((await shard.records()).size).toBe(0);
});

test('BsonShard load is idempotent — second call does not reset records', async () => {
    const shard = newTestShard('s1');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.load(); // should be a no-op because _records is already set
    expect((await shard.records()).size).toBe(1);
});

// ─── setRecord / record / deleteRecord ────────────────────────────────────

test('BsonShard setRecord marks shard dirty', async () => {
    const shard = newTestShard('s1');
    expect(shard.dirty()).toBe(false);
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    expect(shard.dirty()).toBe(true);
});

test('BsonShard record returns undefined for unknown id', async () => {
    const shard = newTestShard('s1');
    expect(await shard.record(recordId1)).toBeUndefined();
});

test('BsonShard setRecord and record round-trip', async () => {
    const shard = newTestShard('s1');
    const rec = makeRecord(recordId1, 'a');
    await shard.setRecord(recordId1, rec);
    expect(await shard.record(recordId1)).toEqual(rec);
});

test('BsonShard setRecord stores multiple records independently', async () => {
    const shard = newTestShard('s1');
    const rec1 = makeRecord(recordId1, 'a');
    const rec2 = makeRecord(recordId2, 'b');
    await shard.setRecord(recordId1, rec1);
    await shard.setRecord(recordId2, rec2);
    expect((await shard.records()).size).toBe(2);
    expect(await shard.record(recordId1)).toEqual(rec1);
    expect(await shard.record(recordId2)).toEqual(rec2);
});

test('BsonShard deleteRecord removes the record and keeps dirty', async () => {
    const shard = newTestShard('s1');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.deleteRecord(recordId1);
    expect(shard.dirty()).toBe(true);
    expect(await shard.record(recordId1)).toBeUndefined();
});

test('BsonShard deleteRecord on nonexistent id does not throw', async () => {
    const shard = newTestShard('s1');
    await expect(shard.deleteRecord(recordId1)).resolves.toBeUndefined();
});

test('BsonShard deleteRecord leaves other records intact', async () => {
    const shard = newTestShard('s1');
    const rec1 = makeRecord(recordId1, 'a');
    const rec2 = makeRecord(recordId2, 'b');
    await shard.setRecord(recordId1, rec1);
    await shard.setRecord(recordId2, rec2);
    await shard.deleteRecord(recordId1);
    expect(await shard.record(recordId1)).toBeUndefined();
    expect(await shard.record(recordId2)).toEqual(rec2);
});

test('BsonShard setRecord getRecord deleteRecord use normalized ids', async () => {
    const shard = newTestShard('s1');
    const record: IInternalRecord = {
        _id: recordId1,
        fields: { name: 'a' },
        metadata: {},
    };
    expect(shard.dirty()).toBe(false);
    await shard.setRecord(recordId1, record);
    expect(shard.dirty()).toBe(true);
    expect(await shard.record(recordId1)).toEqual(record);
    await shard.deleteRecord(recordId1);
    expect(shard.dirty()).toBe(true);
    expect(await shard.record(recordId1)).toBeUndefined();
});

// ─── merkle tree ──────────────────────────────────────────────────────────

test('BsonShard setRecord builds merkle tree', async () => {
    const shard = newTestShard('0');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    const tree = await shard.merkleTree().get();
    expect(tree).toBeDefined();
    expect(tree?.sort).toBeDefined();
});

test('BsonShard deleteRecord drops merkle tree when the last record is removed', async () => {
    const shard = newTestShard('0');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.deleteRecord(recordId1);
    const tree = await shard.merkleTree().get();
    expect(tree).toBeUndefined();
});

test('BsonShard merkle tree is not undefined when one record remains after delete', async () => {
    const shard = newTestShard('0');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.setRecord(recordId2, makeRecord(recordId2, 'b'));
    await shard.deleteRecord(recordId1);
    const tree = await shard.merkleTree().get();
    expect(tree).toBeDefined();
});

// ─── commit ───────────────────────────────────────────────────────────────

test('BsonShard commit is a no-op when not dirty', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    await shard.commit(); // should not throw or write anything
    expect(shard.dirty()).toBe(false);
});

test('BsonShard commit persists records and clears dirty flag', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    await shard.setRecord(recordId1, makeRecord(recordId1, 'hello'));
    await shard.commit();
    expect(shard.dirty()).toBe(false);
});

test('BsonShard commit round-trips records through storage', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    const rec = makeRecord(recordId1, 'hello');
    await shard.setRecord(recordId1, rec);
    await shard.commit();

    // Load a fresh shard from the same storage
    const shard2 = newTestShard('s1', storage);
    await shard2.load();
    expect((await shard2.records()).size).toBe(1);
    expect(await shard2.record(recordId1)).toEqual(rec);
});

test('BsonShard commit round-trips multiple records', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    const rec1 = makeRecord(recordId1, 'a');
    const rec2 = makeRecord(recordId2, 'b');
    const rec3 = makeRecord(recordId3, 'c');
    await shard.setRecord(recordId1, rec1);
    await shard.setRecord(recordId2, rec2);
    await shard.setRecord(recordId3, rec3);
    await shard.commit();

    const shard2 = newTestShard('s1', storage);
    await shard2.load();
    expect((await shard2.records()).size).toBe(3);
    expect(await shard2.record(recordId1)).toEqual(rec1);
    expect(await shard2.record(recordId2)).toEqual(rec2);
    expect(await shard2.record(recordId3)).toEqual(rec3);
});

test('BsonShard commit deletes file when all records are removed', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.commit();

    await shard.deleteRecord(recordId1);
    await shard.commit();
    expect(shard.dirty()).toBe(false);

    // A fresh shard should see no records
    const shard2 = newTestShard('s1', storage);
    await shard2.load();
    expect((await shard2.records()).size).toBe(0);
});

// ─── flush ────────────────────────────────────────────────────────────────

test('BsonShard flush throws when dirty', async () => {
    const shard = newTestShard('s1');
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    expect(() => shard.flush()).toThrow();
});

test('BsonShard flush clears in-memory records after commit', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.commit();
    shard.flush();
    // After flush, records should be reloaded lazily from storage
    expect((await shard.records()).size).toBe(1);
});

test('BsonShard flush followed by setRecord reloads from storage first', async () => {
    const storage = new MockStorage();
    const shard = newTestShard('s1', storage);
    await shard.setRecord(recordId1, makeRecord(recordId1, 'a'));
    await shard.commit();
    shard.flush();

    // Adding a second record after flush should not lose the first
    await shard.setRecord(recordId2, makeRecord(recordId2, 'b'));
    expect((await shard.records()).size).toBe(2);
});
