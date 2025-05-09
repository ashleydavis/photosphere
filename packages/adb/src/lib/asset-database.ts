import { IFileInfo, IStorage } from "storage";
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
export class AssetDatabase {

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
}