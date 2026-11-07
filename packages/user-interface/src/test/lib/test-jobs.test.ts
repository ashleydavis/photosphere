import { pickTestJobDuration, planTestJob, TEST_JOB_KINDS } from "../../lib/test-jobs";

describe("pickTestJobDuration", () => {

    test("runs for at least twenty seconds, so a job can be read before it goes", () => {
        expect(pickTestJobDuration(0)).toBe(20_000);
    });

    test("runs for at most a minute, so a forgotten job clears itself", () => {
        expect(pickTestJobDuration(1)).toBe(60_000);
    });

    test("spreads the range in between", () => {
        expect(pickTestJobDuration(0.5)).toBe(40_000);
    });
});

describe("planTestJob", () => {

    test("plans one task for a single-task job", () => {
        const plan = planTestJob("job-1", TEST_JOB_KINDS[0], 1, [0.5]);

        expect(plan.tasks).toHaveLength(1);
        expect(plan.tasks[0].job?.name).toBe(TEST_JOB_KINDS[0].name);
    });

    test("gives every task in a job the same tag, so they are one row", () => {
        const plan = planTestJob("job-1", TEST_JOB_KINDS[0], 4, [0, 0.25, 0.5, 1]);

        expect(plan.tasks).toHaveLength(4);
        expect(plan.tasks.every(task => task.job?.id === "job-1")).toBe(true);
        expect(plan.tasks.every(task => task.job?.name === TEST_JOB_KINDS[0].name)).toBe(true);
    });

    test("gives the tasks different durations, so they do not all end together", () => {
        const plan = planTestJob("job-1", TEST_JOB_KINDS[0], 4, [0, 0.25, 0.5, 1]);

        expect(new Set(plan.tasks.map(task => task.durationMs)).size).toBe(4);
    });

    test("cancels by the source the tasks are queued under", () => {
        const plan = planTestJob("job-1", TEST_JOB_KINDS[0], 2, [0, 1]);

        // A cancel source that did not match the queue's source would leave Cancel doing nothing.
        expect(plan.source).toBe("job-1");
        expect(plan.tasks.every(task => task.job?.cancelSource === plan.source)).toBe(true);
    });

    test("carries the kind's stages and count onto every task", () => {
        const kind = TEST_JOB_KINDS[1];
        const plan = planTestJob("job-1", kind, 2, [0, 1]);

        expect(plan.tasks.every(task => task.stages === kind.stages)).toBe(true);
        expect(plan.tasks.every(task => task.itemCount === kind.itemCount)).toBe(true);
    });
});

describe("TEST_JOB_KINDS", () => {

    test("every kind has its own name, so several running together are told apart", () => {
        const names = TEST_JOB_KINDS.map(kind => kind.name);
        expect(new Set(names).size).toBe(names.length);
    });

    test("every kind has stages to work through and something to count", () => {
        for (const kind of TEST_JOB_KINDS) {
            expect(kind.stages.length).toBeGreaterThan(1);
            expect(kind.itemCount).toBeGreaterThan(0);
        }
    });
});
