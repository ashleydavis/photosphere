//
// A task that does nothing but take a while, so the job manager can be driven by hand.
//
// Every real job either finishes too fast to look at (a load, a small replication) or needs a large
// database and a long setup to make it last (an import). This one takes as long as it is told to,
// works through named stages reporting a rising count as it goes, and stops when it is cancelled,
// so the interface can be exercised without staging any data at all.
//
// It is reachable only from the developer section of the sidebar, which is hidden unless developer
// mode is switched on.
//

import type { ITaskContext } from "task-queue";
import { sendJobProgress } from "task-queue";
import type { IJobTag } from "task-queue";
import { log } from "utils";

//
// How long each step of the task sleeps before it looks at the clock and the cancel flag again.
//
// Short enough that Cancel feels immediate, long enough that a task lasting a minute does not wake
// thousands of times doing nothing.
//
const STEP_MS = 250;

//
// Input data for the test-job task.
//
export interface ITestJobData {
    //
    // How long the task should run for, in milliseconds.
    //
    durationMs: number;

    //
    // The stages the task works through, in order, an equal share of the time each. Each one names
    // what the job claims to be doing, so the progress line changes as the job goes rather than
    // counting down the same sentence.
    //
    stages: string[];

    //
    // How many things this task pretends to process. The progress line counts up to it, so the
    // detail under the job's name moves the way a real job's does.
    //
    itemCount: number;

    //
    // Names the job this task belongs to. Several tasks carrying the same tag are one row in the
    // interface, which is one of the cases this task exists to demonstrate.
    //
    job?: IJobTag;
}

//
// What the task reports when it finishes.
//
export interface ITestJobResult {
    //
    // How long the task actually ran for, in milliseconds. Shorter than asked for when cancelled.
    //
    elapsedMs: number;

    //
    // True when the task stopped early because it was cancelled.
    //
    cancelled: boolean;
}

//
// The progress line for a task that is the given fraction of the way through.
//
// Exported so the wording can be checked without running a task for half a minute.
//
export function describeTestJobProgress(stages: string[], itemCount: number, fraction: number): string {
    const clamped = Math.min(Math.max(fraction, 0), 0.999);
    const stage = stages[Math.floor(clamped * stages.length)];
    const done = Math.floor(clamped * itemCount) + 1;
    return `${stage}: ${done} of ${itemCount}`;
}

//
// Runs for the requested time, reporting progress as it goes, and stops early when cancelled.
//
export async function testJobHandler(data: ITestJobData, context: ITaskContext): Promise<ITestJobResult> {
    const startedAt = context.timestampProvider.now();
    const endsAt = startedAt + data.durationMs;

    log.info(`Test job "${data.job?.name ?? "untitled"}" running for ${Math.round(data.durationMs / 1000)}s.`);

    while (true) {
        const now = context.timestampProvider.now();
        if (context.isCancelled()) {
            log.info(`Test job "${data.job?.name ?? "untitled"}" cancelled after ${now - startedAt}ms.`);
            return {
                elapsedMs: now - startedAt,
                cancelled: true,
            };
        }

        if (now >= endsAt) {
            break;
        }

        const fraction = (now - startedAt) / data.durationMs;
        sendJobProgress(context, data.job, startedAt, describeTestJobProgress(data.stages, data.itemCount, fraction));

        await new Promise<void>(resolve => setTimeout(resolve, Math.min(STEP_MS, endsAt - now)));
    }

    log.info(`Test job "${data.job?.name ?? "untitled"}" finished.`);

    return {
        elapsedMs: context.timestampProvider.now() - startedAt,
        cancelled: false,
    };
}
