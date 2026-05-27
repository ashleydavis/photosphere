//
// Mock TaskQueue so we can capture constructor args and queue.addTask calls without
// pulling the real implementation (which transitively loads ESM-only `serialize-error`
// via the `utils` package).
//
const mockAddTask = jest.fn();
const mockOnTaskComplete = jest.fn();
const mockShutdown = jest.fn();
const mockTaskQueueConstructor = jest.fn();

jest.mock("task-queue", () => ({
    TaskQueue: jest.fn().mockImplementation((uuidGenerator: unknown, source: unknown) => {
        mockTaskQueueConstructor(uuidGenerator, source);
        return {
            addTask: mockAddTask,
            onTaskComplete: mockOnTaskComplete,
            shutdown: mockShutdown,
        };
    }),
}));

import type { IUuidGenerator } from "utils";
import { importDirectories, importFiles } from "../../context/import-context";
import type { IPlatformContext } from "../../context/platform-context";

//
// Builds a deterministic uuid generator that returns a different value on each call.
//
function makeUuidGenerator(values: string[]): IUuidGenerator {
    let index = 0;
    return {
        generate: () => {
            const value = values[index] ?? `uuid-${index}`;
            index++;
            return value;
        },
    };
}

//
// Builds a minimal platform mock exposing only the pickers used by the helpers.
//
function makePlatform(overrides: Partial<IPlatformContext>): Pick<IPlatformContext, "pickFolder" | "pickFiles"> {
    return {
        pickFolder: overrides.pickFolder || jest.fn(),
        pickFiles: overrides.pickFiles || jest.fn(),
    };
}

describe("importDirectories", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockAddTask.mockImplementation((_type: string, _data: unknown, taskId?: string) => taskId || "auto-task-id");
    });

    test("returns undefined immediately when databasePath is undefined", async () => {
        const pickFolder = jest.fn();
        const platform = makePlatform({ pickFolder });

        const result = await importDirectories({
            platform,
            databasePath: undefined,
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(result).toBeUndefined();
        expect(pickFolder).not.toHaveBeenCalled();
        expect(mockAddTask).not.toHaveBeenCalled();
    });

    test("opens the folder picker with the Import Directory title when no paths are supplied", async () => {
        const pickFolder = jest.fn(() => Promise.resolve("/photos/import"));
        const platform = makePlatform({ pickFolder });

        await importDirectories({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(pickFolder).toHaveBeenCalledWith({ title: "Import Directory" });
    });

    test("queues import-assets with the picked folder when paths are not supplied", async () => {
        const platform = makePlatform({ pickFolder: jest.fn(() => Promise.resolve("/photos/import")) });

        const result = await importDirectories({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(mockAddTask).toHaveBeenCalledWith(
            "import-assets",
            {
                paths: ["/photos/import"],
                storageDescriptor: { databasePath: "/db" },
                sessionId: "session-id",
                dryRun: false,
            },
            "session-id",
        );
        expect(result).toEqual({ importAssetsTaskId: "session-id", sessionId: "session-id" });
    });

    test("returns undefined and does not call addTask when the user cancels the folder picker", async () => {
        const platform = makePlatform({ pickFolder: jest.fn(() => Promise.resolve(undefined)) });

        const result = await importDirectories({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(result).toBeUndefined();
        expect(mockAddTask).not.toHaveBeenCalled();
    });

    test("uses the supplied paths verbatim without opening the picker", async () => {
        const pickFolder = jest.fn();
        const platform = makePlatform({ pickFolder });

        const result = await importDirectories(
            {
                platform,
                databasePath: "/db",
                uuidGenerator: makeUuidGenerator(["session-id"]),
            },
            ["/passed/in/path"],
        );

        expect(pickFolder).not.toHaveBeenCalled();
        expect(mockAddTask).toHaveBeenCalledWith(
            "import-assets",
            {
                paths: ["/passed/in/path"],
                storageDescriptor: { databasePath: "/db" },
                sessionId: "session-id",
                dryRun: false,
            },
            "session-id",
        );
        expect(result).toEqual({ importAssetsTaskId: "session-id", sessionId: "session-id" });
    });
});

describe("importFiles", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockAddTask.mockImplementation((_type: string, _data: unknown, taskId?: string) => taskId || "auto-task-id");
    });

    test("returns undefined immediately when databasePath is undefined", async () => {
        const pickFiles = jest.fn();
        const platform = makePlatform({ pickFiles });

        const result = await importFiles({
            platform,
            databasePath: undefined,
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(result).toBeUndefined();
        expect(pickFiles).not.toHaveBeenCalled();
        expect(mockAddTask).not.toHaveBeenCalled();
    });

    test("opens the files picker with the Import Files title when no paths are supplied", async () => {
        const pickFiles = jest.fn(() => Promise.resolve(["/a.jpg", "/b.jpg"]));
        const platform = makePlatform({ pickFiles });

        await importFiles({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(pickFiles).toHaveBeenCalledWith("Import Files");
    });

    test("queues import-assets with the picked files when paths are not supplied", async () => {
        const platform = makePlatform({ pickFiles: jest.fn(() => Promise.resolve(["/a.jpg", "/b.jpg"])) });

        const result = await importFiles({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(mockAddTask).toHaveBeenCalledWith(
            "import-assets",
            {
                paths: ["/a.jpg", "/b.jpg"],
                storageDescriptor: { databasePath: "/db" },
                sessionId: "session-id",
                dryRun: false,
            },
            "session-id",
        );
        expect(result).toEqual({ importAssetsTaskId: "session-id", sessionId: "session-id" });
    });

    test("returns undefined and does not call addTask when the user cancels the files picker", async () => {
        const platform = makePlatform({ pickFiles: jest.fn(() => Promise.resolve(undefined)) });

        const result = await importFiles({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(result).toBeUndefined();
        expect(mockAddTask).not.toHaveBeenCalled();
    });

    test("returns undefined and does not call addTask when the files picker returns an empty list", async () => {
        const platform = makePlatform({ pickFiles: jest.fn(() => Promise.resolve([])) });

        const result = await importFiles({
            platform,
            databasePath: "/db",
            uuidGenerator: makeUuidGenerator(["session-id"]),
        });

        expect(result).toBeUndefined();
        expect(mockAddTask).not.toHaveBeenCalled();
    });

    test("uses the supplied paths verbatim without opening the picker", async () => {
        const pickFiles = jest.fn();
        const platform = makePlatform({ pickFiles });

        const result = await importFiles(
            {
                platform,
                databasePath: "/db",
                uuidGenerator: makeUuidGenerator(["session-id"]),
            },
            ["/passed/file-a.jpg", "/passed/file-b.jpg"],
        );

        expect(pickFiles).not.toHaveBeenCalled();
        expect(mockAddTask).toHaveBeenCalledWith(
            "import-assets",
            {
                paths: ["/passed/file-a.jpg", "/passed/file-b.jpg"],
                storageDescriptor: { databasePath: "/db" },
                sessionId: "session-id",
                dryRun: false,
            },
            "session-id",
        );
        expect(result).toEqual({ importAssetsTaskId: "session-id", sessionId: "session-id" });
    });
});
