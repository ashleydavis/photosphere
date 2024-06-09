import { IDatabaseOp } from "defs";
import { IAssetData } from "../def/asset-data";

//
// Stores assets to a particular location.
//
export interface IAssetSink {
    //
    // Submits operations to change the database.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;

    //
    // Stores an asset.
    //
    storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;
}