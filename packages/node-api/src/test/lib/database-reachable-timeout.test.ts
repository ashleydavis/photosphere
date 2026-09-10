import type { ITaskContext } from "task-queue";

//
// The bound on finding out whether a database is reachable.
//
// Its own file because it needs `open-storage` mocked, and the other tests of this handler
// deliberately run against a real temporary directory to check what "exists" means. A storage that
// answers nothing cannot be built out of a real directory.
//
// What this protects is a user waiting on an answer. Nothing else bounds the read: the S3 client's own
// request ceiling is ten minutes, set for a phone pushing a large video through the engine bridge, and
// falling through to it leaves someone opening a database on a screen that never resolves. Measured on
// a Pixel 6 against a stopped server reached through an `adb reverse` forward, which accepts the
// connection and then answers nothing, the app said nothing at all for the 300 seconds it was watched
// for. On an emulator the same server refuses the connection at once, which is why this was invisible
// there.
//

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { checkDatabaseExistsHandler } from "../../lib/check-database-exists.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;

//
// A minimal task context. The handler ignores it.
//
const context: ITaskContext = {
    uuidGenerator: { generate: () => "test-id" },
    timestampProvider: { now: () => 0, dateNow: () => new Date(0) },
    sessionId: "test-session",
    maxConcurrentChildTasks: 10,
    taskId: "test-task",
    sendMessage: () => {},
    isCancelled: () => false,
};

describe("checking whether a database is reachable", () => {

    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("gives up when the storage never answers, rather than waiting on the client's ten minute ceiling", async () => {
        // A storage that accepts the question and never answers it, which is what a connection that
        // was accepted by something with nothing behind it looks like from here.
        mockOpenStorage.mockResolvedValue({
            storage: {
                fileExists: () => new Promise<boolean>(() => {}),
            } as any,
            rawStorage: {} as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        });

        jest.useFakeTimers();

        try {
            const checking = checkDatabaseExistsHandler({ databasePath: "s3:bucket/unreachable" }, context);

            // Asserted before time is moved, so a rejection that happened for any other reason cannot
            // be mistaken for the timeout.
            const settled = jest.fn();
            checking.then(settled, settled);
            await Promise.resolve();
            expect(settled).not.toHaveBeenCalled();

            // Past the bound, in one step.
            await jest.advanceTimersByTimeAsync(31_000);

            await expect(checking).rejects.toThrow("timed out");
        }
        finally {
            jest.useRealTimers();
        }
    });

    test("answers normally when the storage does answer", async () => {
        mockOpenStorage.mockResolvedValue({
            storage: {
                fileExists: async () => true,
            } as any,
            rawStorage: {} as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        });

        const result = await checkDatabaseExistsHandler({ databasePath: "s3:bucket/reachable" }, context);

        expect(result.exists).toBe(true);
    });
});
