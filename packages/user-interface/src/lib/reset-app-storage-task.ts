import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type { IResetAppStorageOutcome } from "./reset-device";

//
// Runs the reset-app-storage task and reports what it removed.
//
// The task empties the app's own config and cache directories, which on a phone are both its storage
// sandbox, so this is what takes the databases off a device. It is registered by every platform that
// runs tasks (desktop, the CLI and the dev server through initTaskHandlers, mobile through
// mobile-worker-entry), which is why the reset needs no platform-specific code and no new method on
// the platform context.
//
// The task is given no path, deliberately: the handler reads the two directories it may empty for
// itself, so nothing this side can point it at a user's photos.
//

//
// The outputs of the reset-app-storage worker task.
//
interface IResetAppStorageOutputs {
    // How many entries the task removed, absent when the task reported nothing.
    entriesRemoved?: number;
}

//
// Queues the reset-app-storage task, waits for it, and returns what it removed. Throws when the task
// fails, so a reset that did not happen is never reported as one that did.
//
export async function runResetAppStorageTask(): Promise<IResetAppStorageOutcome> {
    const uuidGenerator = new RandomUuidGenerator();
    // A source of its own, so shutting this queue down cannot cancel another task that happens to
    // share a tag, the way the config tasks each take their own.
    const queue = new TaskQueue(uuidGenerator, `reset-app-storage-${uuidGenerator.generate()}`);
    try {
        // Interactive: the user is waiting in front of a modal that says the reset is running.
        const taskId = queue.addTask("reset-app-storage", {}, undefined, TaskPriority.Interactive);
        const result = await queue.awaitTask(taskId);
        if (!result || result.status !== TaskStatus.Succeeded) {
            throw new Error(`reset-app-storage task did not succeed: ${result?.errorMessage ?? "no result"}`);
        }
        const outputs = (result.outputs ?? {}) as IResetAppStorageOutputs;
        return {
            entriesRemoved: outputs.entriesRemoved ?? 0,
        };
    }
    finally {
        queue.shutdown();
    }
}
