import type { IAsset } from "./asset";
import type { IJobTag } from "task-queue";

export interface ILoadAssetsData {
    databasePath: string;

    //
    // Names the job this task belongs to, so the load shows up in the interface's job list.
    //
    job?: IJobTag;
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

