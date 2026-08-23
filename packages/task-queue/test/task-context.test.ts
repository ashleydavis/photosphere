import { TaskContext } from "../src/lib/task-context";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";

describe("TaskContext", () => {
    test("isCancelled returns false initially", () => {
        const context = new TaskContext(
            new TestUuidGenerator(),
            new TestTimestampProvider(),
            "session-1",
            "task-1",
            jest.fn(),
            10
        );

        expect(context.isCancelled()).toBe(false);
    });

    test("cancel causes isCancelled to return true", () => {
        const context = new TaskContext(
            new TestUuidGenerator(),
            new TestTimestampProvider(),
            "session-1",
            "task-1",
            jest.fn(),
            10
        );

        context.cancel();

        expect(context.isCancelled()).toBe(true);
    });

    test("sendMessage invokes the injected sendMessageFn with the correct argument", () => {
        const sendMessageFn = jest.fn();
        const context = new TaskContext(
            new TestUuidGenerator(),
            new TestTimestampProvider(),
            "session-1",
            "task-1",
            sendMessageFn,
            10
        );

        const msg = { type: "progress", value: 42 };
        context.sendMessage(msg);

        expect(sendMessageFn).toHaveBeenCalledTimes(1);
        expect(sendMessageFn).toHaveBeenCalledWith(msg);
    });

    test("everything the task needs is exposed as provided", () => {
        const uuidGenerator = new TestUuidGenerator();
        const timestampProvider = new TestTimestampProvider();
        const context = new TaskContext(
            uuidGenerator,
            timestampProvider,
            "my-session",
            "my-task",
            jest.fn(),
            7
        );

        expect(context.uuidGenerator).toBe(uuidGenerator);
        expect(context.timestampProvider).toBe(timestampProvider);
        expect(context.sessionId).toBe("my-session");
        expect(context.taskId).toBe("my-task");
        // How many child tasks a task may run at once comes from the platform that built the
        // context, because only it knows what the machine can take.
        expect(context.maxConcurrentChildTasks).toBe(7);
    });
});
