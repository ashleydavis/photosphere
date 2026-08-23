import type { ITaskQueue } from "task-queue";
import { TaskPriority } from "task-queue";

//
// Loads assets from the database using a background task.
// The task will stream batches of assets to the client via task messages.
//
// Interactive, because this is what a tap on a database is waiting for: until it has streamed its
// first page the user is looking at an empty gallery. Queued behind an automatic import's backlog it
// took two minutes and eight seconds to open a database of 2,300 photos on a Pixel 6.
//
export function loadAssets(queue: ITaskQueue, databasePath: string): void {
    queue.addTask("load-assets", { databasePath }, databasePath, TaskPriority.Interactive);
}

