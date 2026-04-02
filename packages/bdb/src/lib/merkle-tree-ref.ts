import { upsertItem, deleteItem, type IMerkleTree, type HashedItem, buildMerkleTree } from "merkle-tree";
import type { IUuidGenerator } from "utils";

//
// Lazily-loaded, committable handle for a merkle tree.
// Works at shard, collection, and database level via injected callbacks.
//
export interface IMerkleRef<T = undefined> {
    //
    // Returns the underlying merkle tree, invoking the loader on first access.
    // Returns undefined when there is no tree (empty shard/collection/database).
    //
    get(): Promise<IMerkleTree<T> | undefined>;

    //
    // Inserts or updates a hashed item in the tree, creating the tree if needed.
    //
    upsert(item: HashedItem): Promise<void>;

    //
    // Removes an item by name. Sets tree to undefined if it becomes empty.
    //
    remove(name: string): Promise<void>;

    //
    // Persists the tree to storage (or deletes it if empty). No-op when not dirty.
    //
    commit(): Promise<void>;

    //
    // Drops the cached tree from memory so the next access reloads from storage.
    // Throws if dirty — call commit() first.
    //
    flush(): void;
}

//
// Concrete lazily-loaded merkle ref.
// The caller supplies load/save/delete callbacks appropriate for the level
// (shard, collection, or database). An optional creator callback is needed
// when upsert() may be called on a level whose tree starts empty (e.g. database).
//
export class MerkleRef<T = undefined> implements IMerkleRef<T> {
    //
    // Cached tree; undefined when empty or not yet loaded.
    //
    private _tree: IMerkleTree<T> | undefined = undefined;

    //
    // True once get() has completed at least once.
    //
    private _loaded = false;

    //
    // True when the in-memory tree differs from what is on disk.
    //
    private _dirty = false;

    constructor(
        //
        // Loads (and, if needed, builds) the tree. Returns undefined when there is no tree.
        //
        private readonly loader: () => Promise<IMerkleTree<T> | undefined>,

        //
        // Saves the tree to storage.
        //
        private readonly saver: (tree: IMerkleTree<T>) => Promise<void>,

        //
        // Deletes the tree from storage.
        //
        private readonly deleter: () => Promise<void>,

        //
        // Creates a new empty tree when upsert() is called and the tree is undefined.
        // Required when the tree may not exist yet (e.g. first collection in a database).
        //
        private readonly creator: () => Promise<IMerkleTree<T>>,
    ) {
    }

    //
    // Returns the tree, invoking the loader on first access.
    //
    async get(): Promise<IMerkleTree<T> | undefined> {
        if (!this._loaded) {
            this._tree = await this.loader();
            this._loaded = true;
        }

        if (this._tree?.dirty) {
            this._tree.merkle = buildMerkleTree(this._tree.sort);
            this._tree.dirty = false;
        }

        return this._tree;
    }

    //
    // Inserts or updates a hashed item in the tree.
    // If the tree is undefined and a creator was supplied, creates a new tree first.
    //
    async upsert(item: HashedItem): Promise<void> {
        let tree = await this.get();
        if (!tree) {
            tree = await this.creator();
        }

        this._tree = upsertItem(tree, item);
        this._dirty = true;
    }

    //
    // Removes an item by name. Sets the tree to undefined if it becomes empty.
    //
    async remove(name: string): Promise<void> {
        const tree = await this.get();
        if (!tree || !tree.sort) {
            return;
        }

        deleteItem(tree, name);

        if (!tree.sort) {
            this._tree = undefined;
        }

        this._dirty = true;
    }

    //
    // Writes the tree to storage (or deletes it if empty); clears the dirty flag.
    //
    async commit(): Promise<void> {
        if (!this._dirty) {
            return;
        }

        if (this._tree) {
            await this.saver(this._tree);
        }
        else {
            await this.deleter();
        }

        this._dirty = false;
    }

    //
    // Drops the cached tree. Throws if dirty — call commit() first.
    //
    flush(): void {
        if (this._dirty) {
            throw new Error('Cannot flush a dirty MerkleRef — call commit() first.');
        }

        this._tree = undefined;
        this._loaded = false;
    }
}
