import type { IJobProgressMessage } from "task-queue";
import { applyJobProgress, applyTaskCompleted, describeJobsIndicator, describeJobListChanges, formatElapsed, type IJob } from "../../lib/jobs";

//
// Builds a job-progress report, so each test only states the part it is about.
//
function progressMessage(overrides: Partial<IJobProgressMessage> & { jobId: string }): IJobProgressMessage {
    return {
        type: "job-progress",
        job: {
            id: overrides.jobId,
            name: overrides.job?.name ?? "Importing photos",
            cancelSource: overrides.job?.cancelSource,
        },
        startedAt: overrides.startedAt ?? 1000,
        progressMessage: overrides.progressMessage,
    };
}

describe("applyJobProgress", () => {

    test("adds a job the first time its id is reported", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({
            jobId: "job-1",
            job: { id: "job-1", name: "Importing photos", cancelSource: "session-1" },
            startedAt: 5000,
            progressMessage: "3 imported, 0 already there",
        }));

        expect(jobs).toEqual([
            {
                id: "job-1",
                name: "Importing photos",
                cancelSource: "session-1",
                startedAt: 5000,
                progressMessage: "3 imported, 0 already there",
                taskIds: ["task-1"],
            },
        ]);
    });

    test("updates the existing job rather than adding a second row", () => {
        const first = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1", progressMessage: "1 imported" }));
        const second = applyJobProgress(first, "task-1", progressMessage({ jobId: "job-1", progressMessage: "9 imported" }));

        expect(second).toHaveLength(1);
        expect(second[0].progressMessage).toBe("9 imported");
        expect(second[0].taskIds).toEqual(["task-1"]);
    });

    test("counts a second task reporting the same job without adding a row", () => {
        const first = applyJobProgress([], "step-1", progressMessage({ jobId: "sync:/db" }));
        const second = applyJobProgress(first, "step-2", progressMessage({ jobId: "sync:/db" }));

        expect(second).toHaveLength(1);
        expect(second[0].taskIds).toEqual(["step-1", "step-2"]);
    });

    test("keeps the earliest start time reported for a job", () => {
        const first = applyJobProgress([], "step-1", progressMessage({ jobId: "sync:/db", startedAt: 1000 }));
        const second = applyJobProgress(first, "step-2", progressMessage({ jobId: "sync:/db", startedAt: 9000 }));

        expect(second[0].startedAt).toBe(1000);
    });

    test("replaces the progress message on every report", () => {
        const first = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1", progressMessage: "a quarter" }));
        const second = applyJobProgress(first, "task-1", progressMessage({ jobId: "job-1", progressMessage: "half" }));

        expect(second[0].progressMessage).toBe("half");
    });

    test("returns the same list when a report says nothing new", () => {
        const first = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1", progressMessage: "9 imported" }));
        const second = applyJobProgress(first, "task-1", progressMessage({ jobId: "job-1", progressMessage: "9 imported" }));

        // Workers report on a timer as well as on progress, so an import sitting on the same counts
        // sends the same report repeatedly. Handing the list back unchanged is what stops each one
        // repainting the row.
        expect(second).toBe(first);
    });

    test("orders jobs by when they started, oldest first", () => {
        const first = applyJobProgress([], "task-late", progressMessage({ jobId: "late", startedAt: 9000 }));
        const second = applyJobProgress(first, "task-early", progressMessage({ jobId: "early", startedAt: 1000 }));

        expect(second.map(job => job.id)).toEqual(["early", "late"]);
    });
});

describe("applyTaskCompleted", () => {

    test("removes the job when its last task completes", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1" }));

        expect(applyTaskCompleted(jobs, "task-1")).toEqual([]);
    });

    test("keeps the job while another of its tasks is still running", () => {
        const first = applyJobProgress([], "step-1", progressMessage({ jobId: "sync:/db" }));
        const second = applyJobProgress(first, "step-2", progressMessage({ jobId: "sync:/db" }));

        const remaining = applyTaskCompleted(second, "step-1");
        expect(remaining).toHaveLength(1);
        expect(remaining[0].taskIds).toEqual(["step-2"]);
    });

    test("returns the same list when no job holds the completed task", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1" }));

        expect(applyTaskCompleted(jobs, "some-hash-file-task")).toBe(jobs);
    });
});

describe("describeJobsIndicator", () => {

    test("shows nothing when nothing is running", () => {
        expect(describeJobsIndicator([])).toBeUndefined();
    });

    test("counts one job rather than naming it, because the navbar has no room", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({
            jobId: "job-1",
            job: { id: "job-1", name: "Replicating to my-holiday-backup", cancelSource: undefined },
        }));

        // A job's name is unbounded and the navbar is the same component on a phone. The names are
        // in the sidebar, one tap away.
        expect(describeJobsIndicator(jobs)?.label).toBe("1 job");
    });

    test("counts the jobs when several are running", () => {
        const first = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1" }));
        const second = applyJobProgress(first, "task-2", progressMessage({ jobId: "job-2" }));

        expect(describeJobsIndicator(second)?.label).toBe("2 jobs");
    });

});

describe("describeJobListChanges", () => {

    test("reports a job that has appeared", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({
            jobId: "job-1",
            job: { id: "job-1", name: "Importing photos", cancelSource: undefined },
        }));

        const changes = describeJobListChanges(new Map(), jobs);
        expect(changes.started).toEqual(["Importing photos"]);
        expect(changes.finished).toEqual([]);
    });

    test("reports a job that has gone, by the name it had", () => {
        const changes = describeJobListChanges(new Map([["job-1", "Importing photos"]]), []);

        expect(changes.started).toEqual([]);
        expect(changes.finished).toEqual(["Importing photos"]);
    });

    test("reports nothing for a job that is still running, so it is logged once", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({ jobId: "job-1" }));

        const first = describeJobListChanges(new Map(), jobs);
        const second = describeJobListChanges(first.names, jobs);

        expect(second.started).toEqual([]);
        expect(second.finished).toEqual([]);
    });

    test("hands back the names to carry into the next comparison", () => {
        const jobs = applyJobProgress([], "task-1", progressMessage({
            jobId: "job-1",
            job: { id: "job-1", name: "Importing photos", cancelSource: undefined },
        }));

        expect(describeJobListChanges(new Map(), jobs).names).toEqual(new Map([["job-1", "Importing photos"]]));
    });

    test("reports one starting and another finishing in the same comparison", () => {
        const jobs = applyJobProgress([], "task-2", progressMessage({
            jobId: "job-2",
            job: { id: "job-2", name: "Syncing database", cancelSource: undefined },
        }));

        const changes = describeJobListChanges(new Map([["job-1", "Importing photos"]]), jobs);
        expect(changes.started).toEqual(["Syncing database"]);
        expect(changes.finished).toEqual(["Importing photos"]);
    });
});

describe("formatElapsed", () => {

    test("reports seconds under a minute", () => {
        expect(formatElapsed(0)).toBe("0s");
        expect(formatElapsed(4_400)).toBe("4s");
        expect(formatElapsed(59_999)).toBe("59s");
    });

    test("reports minutes and seconds from a minute", () => {
        expect(formatElapsed(60_000)).toBe("1m 0s");
        expect(formatElapsed(64_000)).toBe("1m 4s");
        expect(formatElapsed(3_599_000)).toBe("59m 59s");
    });

    test("reports hours and minutes from an hour", () => {
        expect(formatElapsed(3_600_000)).toBe("1h 0m");
        expect(formatElapsed(7_260_000)).toBe("2h 1m");
    });

    test("never reports a negative age when the clocks disagree", () => {
        expect(formatElapsed(-5_000)).toBe("0s");
    });
});
