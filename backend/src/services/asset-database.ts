//
// Implements the asset database.
//

import { IDatabaseOp } from "../lib/ops";
import { AssetCollection, IAssetCollection } from "./asset-collection";
import { StorageDatabase } from "./database";
import { IStorage } from "./storage";
import { StorageDirectory } from "./storage-directory";

export interface IAssetDatabase {

    //
    // Gets a collection of assets by id.
    //
    assetCollection(collectionId: string): IAssetCollection;

    //
    // Applies a set of operations to the database.
    //
    applyOperations(ops: IDatabaseOp[], clientId: string): Promise<void>;
}

export class StorageAssetDatabase implements IAssetDatabase {

    constructor(private storage: IStorage) {}

    assetCollection(collectionId: string): IAssetCollection {
        const storageDirectory = new StorageDirectory(this.storage, `collections/${collectionId}`);
        const storageDatabase = new StorageDatabase(storageDirectory, `collections/${collectionId}`);
        return new AssetCollection(collectionId, storageDirectory, storageDatabase);
    }

    //
    // Applies a set of operations to the database.
    //
    async applyOperations(ops: IDatabaseOp[], clientId: string): Promise<void> {
        for (const op of ops) {
            const assetCollection = this.assetCollection(op.collectionId);
            await assetCollection.applyOperation(op, clientId);
        }
    }
}