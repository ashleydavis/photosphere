import { MerkleRef } from '../lib/merkle-tree-ref';
import { createTree, type IMerkleTree, type HashedItem } from 'merkle-tree';
import { RandomUuidGenerator } from 'utils';

const uuidGenerator = new RandomUuidGenerator();

//
// Creates a simple HashedItem for testing.
//
function makeItem(name: string): HashedItem {
    return {
        name,
        hash: Buffer.from(name),
        length: name.length,
        lastModified: new Date('2024-01-01'),
    };
}

//
// Creates a new empty tree for use as a stub.
//
function makeTree(): IMerkleTree<undefined> {
    return createTree<undefined>(uuidGenerator.generate());
}

//
// Builds a MerkleRef backed by in-memory state (no real storage).
//
function makeRef(initialTree: IMerkleTree<undefined> | undefined = undefined) {
    let stored: IMerkleTree<undefined> | undefined = initialTree;
    let saveCount = 0;
    let deleteCount = 0;

    const loader = async () => stored;
    const saver = async (tree: IMerkleTree<undefined>) => {
        stored = tree;
        saveCount++;
    };
    const deleter = async () => {
        stored = undefined;
        deleteCount++;
    };
    const creator = async () => makeTree();

    const ref = new MerkleRef(loader, saver, deleter, creator);

    return { ref, getSaved: () => stored, getSaveCount: () => saveCount, getDeleteCount: () => deleteCount };
}

test('get returns undefined when loader returns undefined', async () => {
    const { ref } = makeRef(undefined);
    const tree = await ref.get();
    expect(tree).toBeUndefined();
});

test('get returns the tree when loader returns one', async () => {
    const tree = makeTree();
    const { ref } = makeRef(tree);
    const result = await ref.get();
    expect(result).toBe(tree);
});

test('get only calls loader once (caches result)', async () => {
    let callCount = 0;
    const tree = makeTree();
    const ref = new MerkleRef(
        async () => { callCount++; return tree; },
        async () => {},
        async () => {},
        async () => makeTree(),
    );

    await ref.get();
    await ref.get();
    expect(callCount).toBe(1);
});

test('upsert creates a tree via creator when tree is undefined', async () => {
    const { ref } = makeRef(undefined);
    await ref.upsert(makeItem('file1'));
    const tree = await ref.get();
    expect(tree).toBeDefined();
    expect(tree!.sort).toBeDefined();
});

test('upsert inserts item into existing tree', async () => {
    const { ref } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    const tree = await ref.get();
    expect(tree!.sort).toBeDefined();
    expect(tree!.sort!.leafCount).toBe(1);
});

test('upsert marks the ref as dirty', async () => {
    const { ref, getSaveCount } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.commit();
    expect(getSaveCount()).toBe(1);
});

test('remove on empty tree is a no-op', async () => {
    const { ref } = makeRef(undefined);
    await expect(ref.remove('file1')).resolves.toBeUndefined();
    const tree = await ref.get();
    expect(tree).toBeUndefined();
});

test('remove deletes an existing item', async () => {
    const { ref } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.commit();

    // flush to reset dirty, then remove
    ref.flush();
    await ref.remove('file1');
    const tree = await ref.get();
    // After removing the only item, _tree is set to undefined internally
    expect(tree).toBeUndefined();
});

test('remove sets tree to undefined when it becomes empty', async () => {
    const { ref } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));

    // commit and flush so we can remove cleanly
    await ref.commit();
    ref.flush();

    await ref.remove('file1');
    await ref.commit();
    const tree = await ref.get();
    // After commit/flush cycle, stored tree is cleared by deleter
    // get() now reloads from storage, which was deleted
    expect(tree).toBeUndefined();
});

test('commit saves the tree when dirty', async () => {
    const { ref, getSaveCount } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.commit();
    expect(getSaveCount()).toBe(1);
});

test('commit calls deleter when tree is empty after remove', async () => {
    const { ref, getDeleteCount } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.commit();

    ref.flush();
    await ref.remove('file1');
    await ref.commit();
    expect(getDeleteCount()).toBe(1);
});

test('commit is a no-op when not dirty', async () => {
    const { ref, getSaveCount, getDeleteCount } = makeRef(makeTree());
    await ref.commit();
    expect(getSaveCount()).toBe(0);
    expect(getDeleteCount()).toBe(0);
});

test('commit clears the dirty flag', async () => {
    const { ref, getSaveCount } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.commit();
    // second commit should be a no-op
    await ref.commit();
    expect(getSaveCount()).toBe(1);
});

test('flush resets loaded state so next get reloads from storage', async () => {
    let callCount = 0;
    const tree = makeTree();
    const ref = new MerkleRef(
        async () => { callCount++; return tree; },
        async () => {},
        async () => {},
        async () => makeTree(),
    );

    await ref.get();
    ref.flush();
    await ref.get();
    expect(callCount).toBe(2);
});

test('flush throws when dirty', async () => {
    const { ref } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    expect(() => ref.flush()).toThrow();
});

test('flush does not throw when not dirty', async () => {
    const { ref } = makeRef(makeTree());
    expect(() => ref.flush()).not.toThrow();
});

test('multiple upserts accumulate items in the tree', async () => {
    const { ref } = makeRef(makeTree());
    await ref.upsert(makeItem('file1'));
    await ref.upsert(makeItem('file2'));
    await ref.upsert(makeItem('file3'));
    const tree = await ref.get();
    expect(tree!.sort).toBeDefined();
    expect(tree!.sort!.leafCount).toBe(3);
});
