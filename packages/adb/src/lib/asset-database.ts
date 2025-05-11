import { IFileInfo, IStorage, pathJoin } from "storage";
import { MerkleTree } from "./merkle-tree";

//
// The hash and other information about a file.
//
export interface IHashedFile extends IFileInfo {
    //
    // The sha256 hash of the file.
    //
    hash: Buffer;
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
    // Closes the database and saves any outstanding data.
    //
    close(): Promise<void>;

    //
    // Adds a file or directory to the merkle tree.
    //
    addFile(filePath: string, hashedFile: IHashedFile): void;

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
export class AssetDatabase implements IAssetDatabase {

    //
    // The merkle tree that helps protect against corruption.
    //
    private merkleTree: MerkleTree;

    constructor(private readonly assetStorage: IStorage, private readonly metadataStorage: IStorage) {
        this.merkleTree = new MerkleTree(metadataStorage);
    }

    //
    // Creates a new asset database.
    //
    async create(): Promise<void> {

        if (!await this.assetStorage.isEmpty("./")) {
            throw new Error(`Cannot create new media file database in ${this.assetStorage.location}. This storage location already contains files! Please create your database in a new empty directory.`);
        }

        await this.merkleTree.create();
    }

    //
    // Loads an existing asset database.
    //
    async load(): Promise<void> {
        await this.merkleTree.load();
    }

    //
    // Closes the database and saves any outstanding data.
    //
    async close(): Promise<void> {
        await this.merkleTree.save();
    }

    //
    // Adds a file or directory to the merkle tree.
    //
    addFile(filePath: string, hashedFile: IHashedFile): void {
        this.merkleTree.addFileHash({
            fileName: filePath,
            hash: hashedFile.hash,
            length: hashedFile.length,
        })
    }

    //
    // Deletes a file from the merkle tree.
    //
    async deleteFile(filePath: string): Promise<void> {
        const fileInfo = await this.assetStorage.info(filePath);
        const fileSize = fileInfo?.length;
        this.merkleTree.deleteFile(filePath, undefined, fileSize);
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