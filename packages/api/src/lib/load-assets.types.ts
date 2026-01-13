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
    batch: IAsset[];
}

