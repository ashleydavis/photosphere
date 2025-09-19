import { IStorage, pathJoin } from "storage";
import { markFileAsDeleted, createTree, IMerkleTree, loadTree, saveTree, upsertFile } from "./merkle-tree";
import { IUuidGenerator } from "utils";

//
// The hash and other information about a file.
//
export interface IHashedFile {
    //
    // The sha256 hash of the file.
    //
    hash: Buffer;

    //
    // The length of the file in bytes.
    //
    length: number;

    //
    // The last modified date of the file.
    //
    lastModified: Date;
}

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
    load(): Promise<void>;

    //
    // Adds a file or directory to the merkle tree.
    //
    addFile(filePath: string, hashedFile: IHashedFile): Promise<void>;

    //
    // Deletes a file from the merkle tree.
    // This should be called before actually deleting the file from storage.
    //
    deleteFile(filePath: string): Promise<void>;

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
        await saveTree("tree.dat", this.merkleTree, this.metadataStorage);
    }

    //
    // Loads an existing asset database.
    //
    async load(): Promise<void> {
        this.merkleTree = await loadTree("tree.dat", this.metadataStorage);
        if (!this.merkleTree) {
            throw new Error(`Failed to load asset database. No tree found at ${this.metadataStorage.location}/tree.dat.`);
        }
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
    // Saves the database to disk.
    //
    async save(): Promise<void> {
        if (!this.merkleTree) {
            throw new Error("Cannot save database. No database loaded.");
        }
        await saveTree("tree.dat", this.merkleTree, this.metadataStorage);
    }

    //
    // Adds a file or directory to the merkle tree.
    //
    async addFile(filePath: string, hashedFile: IHashedFile): Promise<void> { //todo: check challs have "await"
        if (!this.merkleTree) {
            throw new Error("Cannot add file to database. No database loaded.");
        }
        
        this.merkleTree = upsertFile(this.merkleTree, {
            fileName: filePath,
            hash: hashedFile.hash,
            length: hashedFile.length,
            lastModified: hashedFile.lastModified,
        });
        
        await this.save();
    }

    //
    // Deletes a file from the merkle tree.
    //
    async deleteFile(filePath: string): Promise<void> {
        if (!this.merkleTree) {
            throw new Error("Cannot delete file from database. No database loaded.");
        }
        markFileAsDeleted(this.merkleTree, filePath);

        await this.save();
    }

    //
    // Deletes a directory from the merkle tree.
    //
    async deleteDir(dirPath: string): Promise<void> {
        let next: string | undefined = undefined;
        do {
            const result = await this.assetStorage.listFiles(dirPath, 1000, next);
            for (const fileName of result.names) {
                await this.deleteFile(pathJoin(dirPath, fileName));
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