//
// Starting synthetic background jobs, so the job manager can be driven by hand.
//
// Reachable only from the developer section of the sidebar. Every real job either finishes too fast
// to look at or needs a large database staged first, which makes the interface hard to check and
// impossible to check quickly.
//

import { TaskQueue } from "task-queue";
import type { IUuidGenerator } from "utils";
import type { ITestJobData } from "node-api/src/lib/test-job.worker";

//
// The shortest and longest a synthetic task runs for.
//
// Long enough to read the row, watch the bar move and press Cancel; short enough that a forgotten
// one clears itself rather than sitting in the list for the rest of the session.
//
const SHORTEST_MS = 20_000;
const LONGEST_MS = 60_000;

//
// One kind of synthetic job: what it is called and what it claims to be doing as it runs.
//
export interface ITestJobKind {
    //
    // The name shown on the row and in the navbar.
    //
    name: string;

    //
    // The stages the job works through, an equal share of its time each.
    //
    stages: string[];

    //
    // How many things it pretends to process, counted up in the progress line.
    //
    itemCount: number;
}

//
// The synthetic jobs the developer sidebar can start. Deliberately varied: different names, different
// stage wording and different counts, so several running together look like real, distinct work
// rather than the same row repeated.
//
export const TEST_JOB_KINDS: ITestJobKind[] = [
    {
        name: "Indexing photos",
        stages: ["Scanning folders", "Reading metadata", "Building index"],
        itemCount: 2400,
    },
    {
        name: "Generating thumbnails",
        stages: ["Decoding originals", "Resizing", "Writing thumbnails"],
        itemCount: 860,
    },
    {
        name: "Backing up database",
        stages: ["Copying records", "Copying files", "Verifying copies"],
        itemCount: 1200,
    },
    {
        name: "Checking integrity",
        stages: ["Reading merkle tree", "Comparing hashes", "Writing report"],
        itemCount: 540,
    },
];

//
// How long one synthetic task should run for: somewhere in the range above.
//
export function pickTestJobDuration(random: number): number {
    return Math.round(SHORTEST_MS + (random * (LONGEST_MS - SHORTEST_MS)));
}

//
// What one synthetic job is made of, so a caller can queue it without knowing how the pieces fit
// together and a test can check the pieces without running anything.
//
export interface ITestJobPlan {
    //
    // The source the tasks are queued under, which is also what cancelling the job cancels.
    //
    source: string;

    //
    // The input data for each task in the job, in the order they are queued.
    //
    tasks: ITestJobData[];
}

//
// Plans a job made of the given number of tasks, all carrying the same job tag so the interface
// shows them as one row that stays until the last of them finishes.
//
// `randoms` supplies one value in [0, 1) per task, so the tasks finish at different times, which is
// what makes a grouped job worth looking at.
//
export function planTestJob(jobId: string, kind: ITestJobKind, taskCount: number, randoms: number[]): ITestJobPlan {
    const tasks: ITestJobData[] = [];
    for (let taskIndex = 0; taskIndex < taskCount; taskIndex += 1) {
        tasks.push({
            durationMs: pickTestJobDuration(randoms[taskIndex]),
            stages: kind.stages,
            itemCount: kind.itemCount,
            job: {
                id: jobId,
                name: kind.name,
                cancelSource: jobId,
            },
        });
    }

    return {
        source: jobId,
        tasks,
    };
}

//
// Queues a planned job. The queue is left running: its tasks outlive this call, which is the whole
// point of a background job.
//
export function startTestJob(uuidGenerator: IUuidGenerator, plan: ITestJobPlan): void {
    const queue = new TaskQueue(uuidGenerator, plan.source);
    for (const task of plan.tasks) {
        queue.addTask("test-job", task);
    }
}
