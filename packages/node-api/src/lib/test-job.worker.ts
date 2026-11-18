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
