import { applyJobProgress, applyTaskCompleted, emptyJobList, IJobProgressMessage } from "../lib/job-list";

function progress(jobId: string, progressMessage: string): IJobProgressMessage {
    return {
        type: "job-progress",
        job: {
            id: jobId,
            name: `Job ${jobId}`,
            cancelSource: "source",
        },
        startedAt: 1000,
        progressMessage,
    };
}

describe("job list", () => {
    test("a first job-progress message adds the job", () => {
        const list = applyJobProgress(emptyJobList(), "task-1", progress("a", "starting"));
        expect(list.jobs).toEqual([
            {
                id: "a",
                name: "Job a",
                cancelSource: "source",
                startedAt: 1000,
                progressMessage: "starting",
            },
        ]);
    });

    test("a later message updates what the job is doing without adding a second job", () => {
        let list = applyJobProgress(emptyJobList(), "task-1", progress("a", "starting"));
        list = applyJobProgress(list, "task-1", progress("a", "halfway"));
        expect(list.jobs.length).toBe(1);
        expect(list.jobs[0].progressMessage).toBe("halfway");
    });

    test("the job is dropped when its only task completes", () => {
        let list = applyJobProgress(emptyJobList(), "task-1", progress("a", "working"));
        list = applyTaskCompleted(list, "task-1");
        expect(list.jobs).toEqual([]);
        expect(list.taskJobIds).toEqual({});
    });

    test("the job stays until the last task carrying its id completes", () => {
        let list = applyJobProgress(emptyJobList(), "parent", progress("a", "parent working"));
        list = applyJobProgress(list, "child-1", progress("a", "child working"));
        list = applyJobProgress(list, "child-2", progress("a", "child working"));
        list = applyTaskCompleted(list, "child-1");
        expect(list.jobs.length).toBe(1);
        list = applyTaskCompleted(list, "child-2");
        expect(list.jobs.length).toBe(1);
        list = applyTaskCompleted(list, "parent");
        expect(list.jobs.length).toBe(0);
    });

    test("completing a task that reported no job changes nothing", () => {
        const list = applyJobProgress(emptyJobList(), "task-1", progress("a", "working"));
        expect(applyTaskCompleted(list, "other-task")).toBe(list);
    });

    test("separate jobs are listed in the order they first reported", () => {
        let list = applyJobProgress(emptyJobList(), "t1", progress("a", "x"));
        list = applyJobProgress(list, "t2", progress("b", "y"));
        expect(list.jobs.map(job => job.id)).toEqual(["a", "b"]);
        list = applyTaskCompleted(list, "t1");
        expect(list.jobs.map(job => job.id)).toEqual(["b"]);
    });
});
