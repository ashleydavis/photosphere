import { IAssetData } from "../defs/asset-data";
import { IDatabaseOp } from "../defs/ops";

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