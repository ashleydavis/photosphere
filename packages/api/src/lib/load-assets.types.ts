import type { IAsset } from "defs";

// No data needed - all configuration is hardcoded in the backend
export interface ILoadAssetsData {
}

export interface ILoadAssetsResult {
    totalAssets: number;
    batchesSent: number;
}

export interface IAssetPageMessage {
    type: "asset-page";
    batch: IAsset[];
}

