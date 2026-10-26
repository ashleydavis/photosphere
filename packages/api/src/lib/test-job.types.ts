//
// The data the user interface queues the test-job background task with, the task the developer page starts to exercise the jobs list.
//

import type { IJobTag } from "task-queue";

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
