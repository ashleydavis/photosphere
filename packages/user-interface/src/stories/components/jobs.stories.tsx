import React from "react";
import { Navbar } from "../../components/navbar";
import { JobsDialog } from "../../components/jobs-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IJobsContext } from "../../context/jobs-context";
import type { IJob } from "../../lib/jobs";
import type { IStory } from "../types";

//
// A job that started the given number of seconds ago, so the elapsed time in each story is a fixed,
// readable figure rather than whatever the clock happened to say when the screenshot was taken.
//
function jobStartedSecondsAgo(id: string, name: string, secondsAgo: number, progressMessage: string | undefined, cancelSource: string | undefined): IJob {
    return {
        id,
        name,
        cancelSource,
        startedAt: Date.now() - (secondsAgo * 1000),
        progressMessage,
        taskIds: [`${id}-task`],
    };
}

//
// Supplies a fixed job list, because the mock platform reports no running tasks and the real
// provider would therefore always be empty.
//
function jobsContext(jobs: IJob[]): IJobsContext {
    return {
        jobs,
        cancelJob: noOp,
        cancelAllJobs: noOp,
        canCancelAny: jobs.some(job => job.cancelSource !== undefined),
    };
}

//
// One import running: the case where the navbar names the job rather than counting it.
//
const oneJob = [
    jobStartedSecondsAgo("session-1", "Importing photos", 74, "128 imported, 12 already there", "session-1"),
];

//
// Every kind of job at once, including one that cannot be cancelled from here (the background sync),
// so both kinds of row can be checked side by side.
//
const everyJob = [
    jobStartedSecondsAgo("session-1", "Importing photos", 74, "128 imported, 12 already there", "session-1"),
    jobStartedSecondsAgo("load:/photos/db", "Loading assets", 51, "1200 assets loaded", "/photos/db"),
    jobStartedSecondsAgo("replicate:/backup", "Replicating to backup", 32, "Copied 214 files, 96 records", "/photos/db"),
    jobStartedSecondsAgo("sync:/photos/db", "Syncing database", 8, "12 changes synced", undefined),
];

export const stories: IStory[] = [
    {
        id: "jobs/navbar-one",
        name: "Navbar Job Indicator (one job)",
        category: "Components",
        render: () => (
            <MockProviders jobsContext={jobsContext(oneJob)}>
                <Navbar
                    sidebarOpen={false}
                    setSidebarOpen={noOp}
                    setRightSidebarOpen={noOp}
                    onOpenConfiguration={noOp}
                    />
            </MockProviders>
        ),
    },
    {
        id: "jobs/navbar-several",
        name: "Navbar Job Indicator (several jobs)",
        category: "Components",
        render: () => (
            <MockProviders jobsContext={jobsContext(everyJob)}>
                <Navbar
                    sidebarOpen={false}
                    setSidebarOpen={noOp}
                    setRightSidebarOpen={noOp}
                    onOpenConfiguration={noOp}
                    />
            </MockProviders>
        ),
    },
    {
        id: "jobs/dialog-one",
        name: "Jobs Dialog (one job)",
        category: "Components",
        render: () => (
            <MockProviders jobsContext={jobsContext(oneJob)}>
                <JobsDialog open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
    {
        id: "jobs/dialog-every-job",
        name: "Jobs Dialog (every job)",
        category: "Components",
        render: () => (
            <MockProviders jobsContext={jobsContext(everyJob)}>
                <JobsDialog open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
