import type { ITaskQueue } from "task-queue";

//
// Loads assets from the database using a background task
// The task will stream batches of assets to the client via task messages
//
export function loadAssets(queue: ITaskQueue, databasePath: string): void {
    queue.addTask("load-assets", { databasePath });
}

