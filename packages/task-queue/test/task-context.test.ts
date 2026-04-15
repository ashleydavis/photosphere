import { TaskContext } from "../src/lib/task-context";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";

describe("TaskContext", () => {
    test("isCancelled returns false initially", () => {
        const context = new TaskContext(
            new TestUuidGenerator(),
            new TestTimestampProvider(),
            "session-1",
            "task-1",
            jest.fn()
        );

        expect(context.isCancelled()).toBe(false);
    });

    test("cancel causes isCancelled to return true", () => {
        const context = new TaskContext(
            new TestUuidGenerator(),
            new TestTimestampProvider(),
            "session-1",
            "task-1",
            jest.fn()
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
            sendMessageFn
        );

        const msg = { type: "progress", value: 42 };
        context.sendMessage(msg);

        expect(sendMessageFn).toHaveBeenCalledTimes(1);
        expect(sendMessageFn).toHaveBeenCalledWith(msg);
    });

    test("uuidGenerator, timestampProvider, sessionId, and taskId are exposed as provided", () => {
        const uuidGenerator = new TestUuidGenerator();
        const timestampProvider = new TestTimestampProvider();
        const context = new TaskContext(
            uuidGenerator,
            timestampProvider,
            "my-session",
            "my-task",
            jest.fn()
        );

        expect(context.uuidGenerator).toBe(uuidGenerator);
        expect(context.timestampProvider).toBe(timestampProvider);
        expect(context.sessionId).toBe("my-session");
        expect(context.taskId).toBe("my-task");
    });
});
