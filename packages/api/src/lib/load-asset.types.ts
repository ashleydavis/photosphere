export interface ILoadAssetData {
    assetId: string;
    assetType: string;
}

export interface ILoadAssetResult {
    assetId: string;
    assetType: string;
    assetData: string; // base64 encoded asset data
}

