import type { ITaskContext } from "task-queue";
import { describeTestJobProgress, testJobHandler } from "../../lib/test-job.worker";

const STAGES = ["Scanning folders", "Reading metadata", "Building index"];

//
// Builds a task context whose clock the test drives, so a job that claims to run for a minute is
// over in a moment.
//
function makeContext(cancelAfterCalls: number): ITaskContext {
    let clock = 1000;
    let cancelChecks = 0;
    return {
        uuidGenerator: { generate: () => "test-uuid" },
        timestampProvider: {
            now: () => {
                clock += 100;
                return clock;
            },
            dateNow: () => new Date(clock),
        },
        sessionId: "session-1",
        taskId: "task-1",
        sendMessage: jest.fn(),
        isCancelled: () => {
            cancelChecks += 1;
            return cancelChecks > cancelAfterCalls;
        },
        maxConcurrentChildTasks: 1,
    };
}

describe("describeTestJobProgress", () => {

    test("names the stage the job has reached", () => {
        expect(describeTestJobProgress(STAGES, 300, 0)).toContain("Scanning folders");
        expect(describeTestJobProgress(STAGES, 300, 0.5)).toContain("Reading metadata");
        expect(describeTestJobProgress(STAGES, 300, 0.9)).toContain("Building index");
    });

    test("counts up as the job goes", () => {
        expect(describeTestJobProgress(STAGES, 300, 0)).toBe("Scanning folders: 1 of 300");
        expect(describeTestJobProgress(STAGES, 300, 0.5)).toBe("Reading metadata: 151 of 300");
    });

    test("never runs past the last stage or the last item", () => {
        expect(describeTestJobProgress(STAGES, 300, 1)).toBe("Building index: 300 of 300");
        expect(describeTestJobProgress(STAGES, 300, 5)).toBe("Building index: 300 of 300");
    });
});

describe("testJobHandler", () => {

    test("stops early when cancelled, and says so", async () => {
        const context = makeContext(0);

        const result = await testJobHandler({
            durationMs: 60_000,
            stages: STAGES,
            itemCount: 300,
            job: {
                id: "job-1",
                name: "Indexing photos",
                cancelSource: "job-1",
            },
        }, context);

        expect(result.cancelled).toBe(true);
    });

    test("reports its job as it runs", async () => {
        const context = makeContext(100);

        await testJobHandler({
            durationMs: 300,
            stages: STAGES,
            itemCount: 300,
            job: {
                id: "job-1",
                name: "Indexing photos",
                cancelSource: "job-1",
            },
        }, context);

        const jobMessages = (context.sendMessage as jest.Mock).mock.calls
            .map(call => call[0])
            .filter(message => message.type === "job-progress");

        expect(jobMessages.length).toBeGreaterThan(0);
        expect(jobMessages[0].job.name).toBe("Indexing photos");
    });

    test("reports no job when queued without a tag", async () => {
        const context = makeContext(100);

        await testJobHandler({
            durationMs: 300,
            stages: STAGES,
            itemCount: 300,
        }, context);

        const jobMessages = (context.sendMessage as jest.Mock).mock.calls
            .map(call => call[0])
            .filter(message => message.type === "job-progress");

        expect(jobMessages).toHaveLength(0);
    });
});
