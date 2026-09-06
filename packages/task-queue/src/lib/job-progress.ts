//
// Reporting a task's progress as a user-visible job.
//

import type { IJobProgressMessage, IJobTag, ITaskContext } from "./types";

//
// Reports a job's progress from inside a task handler.
//
// Does nothing when the task carries no job tag, which is how a task nobody asked to see stays out
// of the interface without its handler having to know that. Automatic import is the case that
// matters: it is the same handler as a manual import, and it runs for as long as the setting is on,
// so a row for it would never go away.
//
export function sendJobProgress(context: ITaskContext, job: IJobTag | undefined, startedAt: number, progressMessage: string | undefined): void {
    if (!job) {
        return;
    }

    const message: IJobProgressMessage = {
        type: "job-progress",
        job,
        startedAt,
        progressMessage,
    };
    context.sendMessage(message);
}
