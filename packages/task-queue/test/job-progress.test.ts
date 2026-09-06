import type { ITaskContext } from "../src/lib/types";
import { sendJobProgress } from "../src/lib/job-progress";

//
// Builds a task context that records the messages a handler sends through it.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: { generate: () => "test-uuid" },
        timestampProvider: { now: () => 0, dateNow: () => new Date(0) },
        sessionId: "session-1",
        taskId: "task-1",
        sendMessage: jest.fn(),
        isCancelled: () => false,
        maxConcurrentChildTasks: 1,
    };
}

describe("sendJobProgress", () => {

    test("sends the whole job with every report, so a listener that joined late learns all of it", () => {
        const context = makeContext();

        sendJobProgress(
            context,
            {
                id: "job-1",
                name: "Importing photos",
                cancelSource: "session-1",
            },
            5000,
            "12 imported"
        );

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "job-progress",
            job: {
                id: "job-1",
                name: "Importing photos",
                cancelSource: "session-1",
            },
            startedAt: 5000,
            progressMessage: "12 imported",
        });
    });

    test("carries a job that has not said what it is doing yet", () => {
        const context = makeContext();

        sendJobProgress(context, { id: "job-1", name: "Syncing database" }, 5000, undefined);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "job-progress",
            job: {
                id: "job-1",
                name: "Syncing database",
            },
            startedAt: 5000,
            progressMessage: undefined,
        });
    });

    test("sends nothing for a task that carries no job tag", () => {
        const context = makeContext();

        sendJobProgress(context, undefined, 5000, "12 imported");

        expect(context.sendMessage).not.toHaveBeenCalled();
    });
});
