import type { IAsset } from "defs";

export interface ILoadAssetsData {
    databasePath: string;
}

export interface ILoadAssetsResult {
    totalAssets: number;
    batchesSent: number;
}

export interface IAssetPageMessage {
    type: "asset-page";
    //
    // The database path this batch belongs to. Used by the frontend to discard messages
    // that arrive after the database has been switched or closed.
    //
    databasePath: string;
    batch: IAsset[];
}

