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

