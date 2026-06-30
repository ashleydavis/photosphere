/**
 * @jest-environment jsdom
 */
import { TaskQueue } from "task-queue";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("task-queue", () => ({
    TaskQueue: jest.fn(),
}));

jest.mock("utils", () => ({
    RandomUuidGenerator: jest.fn().mockImplementation(() => ({ generate: () => "uuid-1" })),
}));

import { renderHook, act } from "@testing-library/react";
import { useMobileAssetServer } from "../lib/use-mobile-asset-server";

const MockTaskQueue = TaskQueue as unknown as jest.Mock;

//
// Captures the constructed fake queue and the registered asset-server-ready handler.
//
interface IFakeQueue {
    // The handler registered via onTaskMessage for asset-server-ready.
    readyHandler?: (data: { taskId: string; message: { type: string; port: number; host: string } }) => void;

    // Records of addTask calls.
    added: Array<{ type: string; data: unknown }>;

    // Whether shutdown was called.
    shutdownCalled: boolean;
}

describe("useMobileAssetServer", () => {
    let fake: IFakeQueue;

    beforeEach(() => {
        fake = { added: [], shutdownCalled: false };
        MockTaskQueue.mockImplementation(() => ({
            onTaskMessage: (messageType: string, handler: IFakeQueue["readyHandler"]) => {
                if (messageType === "asset-server-ready") {
                    fake.readyHandler = handler;
                }
                return () => { /* unsubscribe */ };
            },
            addTask: (type: string, data: unknown) => {
                fake.added.push({ type, data });
                return "task-1";
            },
            shutdown: () => { fake.shutdownCalled = true; },
        }));
    });

    test("starts the asset-server task on mount", () => {
        renderHook(() => useMobileAssetServer());

        expect(fake.added).toEqual([{ type: "asset-server", data: { port: 0 } }]);
    });

    test("returns the default url before the server reports ready", () => {
        const { result } = renderHook(() => useMobileAssetServer());

        expect(result.current).toBe("http://localhost:3001");
    });

    test("updates the url to the bound port once asset-server-ready arrives", () => {
        const { result } = renderHook(() => useMobileAssetServer());

        act(() => {
            fake.readyHandler!({ taskId: "task-1", message: { type: "asset-server-ready", port: 54321, host: "127.0.0.1" } });
        });

        expect(result.current).toBe("http://localhost:54321");
    });

    test("shuts the queue down on unmount", () => {
        const { unmount } = renderHook(() => useMobileAssetServer());

        unmount();

        expect(fake.shutdownCalled).toBe(true);
    });
});
