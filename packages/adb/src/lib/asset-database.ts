import { IStorage, pathJoin } from "storage";
import { createTree, IMerkleTree, loadTree, saveTree, upsertItem, IHashedData, deleteItem, buildMerkleTree } from "merkle-tree";
import { IUuidGenerator, log } from "utils";

//
// Manages a generic database of files and the hash tree that protects against corruption.
//
export interface IAssetDatabase {
    //
    // Creates a new asset database.
    //
    create(): Promise<void>;

    //
    // Loads an existing asset database.
    //
    load(): Promise<boolean>;

    //
    // Adds a file or directory to the merkle tree.
    //
    addFile(filePath: string, hashedFile: IHashedData): void;

    //
    // Updates or inserts a file in the merkle tree.
    //
    upsertFile(filePath: string, hashedFile: IHashedData): void;

    //
    // Deletes a file from the merkle tree.
    // This should be called before actually deleting the file from storage.
    //
    deleteFile(filePath: string): void;

    //
    // Deletes a directory from the merkle tree.
    // This should be called before actually deleting the directory from storage.
    //
    deleteDir(dirPath: string): Promise<void>;
}

//
// Manages a generic database of files and the hash tree that protects against corruption.
//
export class AssetDatabase<DatabaseMetadata> implements IAssetDatabase {

    //
    // The merkle tree that helps protect against corruption.
    //
    private merkleTree: IMerkleTree<DatabaseMetadata> | undefined = undefined;

    constructor(
        private readonly assetStorage: IStorage, 
        private readonly metadataStorage: IStorage,        
        private readonly uuidGenerator: IUuidGenerator        
    ) {
    }

    //
    // Creates a new asset database.
    //
    async create(): Promise<void> {
        if (!await this.assetStorage.isEmpty("./")) {
            throw new Error(`Cannot create new media file database in ${this.assetStorage.location}. This storage location already contains files! Please create your database in a new empty directory.`);
        }

        this.merkleTree = createTree(this.uuidGenerator.generate());
    }

    //
    // Loads an existing asset database.
    //
    async load(): Promise<boolean> {
        this.merkleTree = await loadTree("tree.dat", this.metadataStorage);
        if (!this.merkleTree) {
            return false;
        }

        return true;
    }

    //
    // Gets the merkle tree.
    //
    getMerkleTree(): IMerkleTree<DatabaseMetadata> {
        if (!this.merkleTree) {
            throw new Error("Cannot access merkle tree. No database loaded.");
        }
        return this.merkleTree;
    }

    //
    // Gets the metadata storage.
    //
    getMetadataStorage(): IStorage {
        return this.metadataStorage;
    }

    //
    // Saves the database to disk.
    //
    async save(): Promise<void> {
        if (!this.merkleTree) {
            throw new Error("Cannot save database. No database loaded.");
        }

        if (this.merkleTree.dirty) {
            this.merkleTree.merkle = buildMerkleTree(this.merkleTree.sort);
            this.merkleTree.dirty = false;
        }

        await saveTree("tree.dat", this.merkleTree, this.metadataStorage);
    }

    //
    // Adds a file or directory to the merkle tree.
    //
    addFile(filePath: string, hashedFile: IHashedData): void {
        if (!this.merkleTree) {
            throw new Error("Cannot add file to database. No database loaded.");
        }

        if (filePath.startsWith("metadata/")) {
            return;
        }
        
        this.merkleTree = upsertItem(this.merkleTree, {
            name: filePath,
            hash: hashedFile.hash,
            length: hashedFile.length,
            lastModified: hashedFile.lastModified,
        });
    }

    //
    // Updates or inserts a file in the merkle tree.
    //
    upsertFile(filePath: string, hashedFile: IHashedData): void {
        if (!this.merkleTree) {
            throw new Error("Cannot upsert file to database. No database loaded.");
        }

        if (filePath.startsWith("metadata/")) {
            return;
        }

        this.merkleTree = upsertItem(this.merkleTree, {
            name: filePath,
            hash: hashedFile.hash,
            length: hashedFile.length,
            lastModified: hashedFile.lastModified,
        });
    };

    //
    // Deletes a file from the merkle tree.
    //
    deleteFile(filePath: string): void {
        if (!this.merkleTree) {
            throw new Error("Cannot delete file from database. No database loaded.");
        }

        if (filePath.startsWith("metadata/")) {
            return;
        }

        deleteItem<DatabaseMetadata>(this.merkleTree, filePath);
    }

    //
    // Deletes a directory from the merkle tree.
    //
    async deleteDir(dirPath: string): Promise<void> {
        let next: string | undefined = undefined;
        do {
            const result = await this.assetStorage.listFiles(dirPath, 1000, next);
            for (const fileName of result.names) {
                this.deleteFile(pathJoin(dirPath, fileName));
            }
            next = result.next;
        } while (next);

        next = undefined;
        do {
            const result = await this.assetStorage.listDirs(dirPath, 1000, next);
            for (const dirName of result.names) {
                await this.deleteDir(pathJoin(dirPath, dirName));
            }
            next = result.next;
        } while (next);    
    }
}