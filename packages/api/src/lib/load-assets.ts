import type { ITaskQueue } from "task-queue";
import { TaskPriority } from "task-queue";
import type { ILoadAssetsData } from "./load-assets.types";

//
// Loads assets from the database using a background task.
// The task will stream batches of assets to the client via task messages.
//
// Interactive, because this is what a tap on a database is waiting for: until it has streamed its
// first page the user is looking at an empty gallery. Queued behind an automatic import's backlog it
// took two minutes and eight seconds to open a database of 2,300 photos on a Pixel 6.
//
// loadId identifies this one load, and the caller must also build the queue it passes with this id as
// its source. It is deliberately not the database path: a cancel takes a source, so a load tagged with
// the path is cancelled by anything that cancels that path, which is every other load of the same
// database. A cancelled load stops paging and reports success with no assets, so cancelling a
// superseded load of a database killed the replacement and both reported 0 assets, leaving the gallery
// empty. Smoke test 26, s3-database-lifecycle, failed that way on Windows and macOS.
//
export function loadAssets(queue: ITaskQueue, databasePath: string, loadId: string): void {
    const data: ILoadAssetsData = {
        databasePath,
        job: {
            id: `load:${databasePath}`,
            name: "Loading assets",
            cancelSource: loadId,
        },
    };
    queue.addTask("load-assets", data, loadId, TaskPriority.Interactive);
}

