import { TaskStatus, setQueueBackend } from "task-queue";
import type { IQueueBackend } from "task-queue";
import { replicateDatabase } from "../../lib/replicate-database";
import type { IReplicateDatabaseData } from "api";
import type { IUuidGenerator } from "utils";

//
// Unit tests for replicateDatabase's queue wiring.
//
// The source tag is the point of these tests. A replication tags its queue with the database being
// replicated and shuts that queue down when it finishes, which cancels the source. That is correct,
// and it must stay correct: the mobile engine pool used to remember a cancelled source for the life
// of the app, and the tempting workaround was to give each replication a unique throwaway tag so the
// cancellation never collided. That hid the fault instead of fixing it. The fix belongs in the pool,
// which now re-arms a source when a task is queued, so this asserts the tag is the database path and
// nothing else, to stop the workaround creeping back in.
//

//
// Hands out predictable ids so a test can assert on them.
//
class SequentialUuidGenerator implements IUuidGenerator {
    private nextId = 0;

    //
    // Returns the next id in the sequence.
    //
    generate(): string {
        this.nextId += 1;
        return `uuid-${this.nextId}`;
    }
}

//
// A backend that records the source every task was queued under, and completes each task
// successfully as soon as it is added.
//
function makeRecordingBackend(): { backend: IQueueBackend, sources: string[], cancelled: string[] } {
    const sources: string[] = [];
    const cancelled: string[] = [];
    const addedListeners = new Map<string, ((taskId: string) => void)[]>();
    let completionListener: ((result: any) => void) | undefined;
    let nextTaskNumber = 0;

    const backend: IQueueBackend = {
        addTask: (type: string, data: any, source: string, taskId?: string): string => {
            sources.push(source);
            nextTaskNumber += 1;
            const id = taskId ?? `task-${nextTaskNumber}`;

            for (const listener of addedListeners.get(source) ?? []) {
                listener(id);
            }

            // Complete on a later turn so awaitTask has subscribed by the time this fires.
            Promise.resolve().then(() => {
                if (completionListener) {
                    completionListener({
                        taskId: id,
                        type,
                        source,
                        status: TaskStatus.Succeeded,
                        inputs: data,
                        outputs: { filesCopied: 0 },
                    });
                }
            });

            return id;
        },
        onTaskAdded: (source: string, callback: (taskId: string) => void) => {
            const existing = addedListeners.get(source);
            if (existing) {
                existing.push(callback);
            }
            else {
                addedListeners.set(source, [callback]);
            }
            return () => undefined;
        },
        onTaskComplete: (listener: (result: any) => void) => {
            completionListener = listener;
            return () => {
                completionListener = undefined;
            };
        },
        onTaskMessage: () => () => undefined,
        onAnyTaskMessage: () => () => undefined,
        cancelTasks: (source: string) => {
            cancelled.push(source);
        },
        onTasksCancelled: () => () => undefined,
        shutdown: () => undefined,
    };

    return { backend, sources, cancelled };
}

describe("replicateDatabase queue source", () => {

    test("queues the replication under the source database's path", async () => {
        const { backend, sources } = makeRecordingBackend();
        setQueueBackend(backend);

        const data = { sourcePath: "/photos/my-database", destPath: "/backup/my-database" } as IReplicateDatabaseData;
        await replicateDatabase(new SequentialUuidGenerator(), data);

        expect(sources).toEqual(["/photos/my-database"]);
    });

    test("does not tag the queue with a generated id", async () => {
        const { backend, sources } = makeRecordingBackend();
        setQueueBackend(backend);

        const data = { sourcePath: "/photos/my-database", destPath: "/backup/my-database" } as IReplicateDatabaseData;
        await replicateDatabase(new SequentialUuidGenerator(), data);

        // A throwaway tag would carry one of the generator's ids. The path must be used verbatim.
        for (const source of sources) {
            expect(source).not.toMatch(/uuid-/);
        }
    });

    test("cancels that same source when it shuts the queue down", async () => {
        const { backend, cancelled } = makeRecordingBackend();
        setQueueBackend(backend);

        const data = { sourcePath: "/photos/my-database", destPath: "/backup/my-database" } as IReplicateDatabaseData;
        await replicateDatabase(new SequentialUuidGenerator(), data);

        // This is what made a second replication vanish before the pool was fixed, so it is recorded
        // here rather than left implicit.
        expect(cancelled).toEqual(["/photos/my-database"]);
    });
});
