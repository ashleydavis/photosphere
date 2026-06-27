import { registerHandler, ITaskContext } from "task-queue";
import { buildHost, notImplementedMessage, IHost } from "../lib/host-functions";
import { runTask } from "../lib/mobile-worker-runtime";

//
// Builds a raw host that deliberately omits the sha256 function so the
// NOT IMPLEMENTED stub machinery can be exercised.
//
function createHostWithoutSha256(): IHost {
    const rawHost = {
        platform: "android",
        sessionId: "session-xyz",
        sendMessage: () => { /* no-op for these tests */ },
        isCancelled: () => false,
    } as unknown as IHost;

    return rawHost;
}

describe("host bridge NOT IMPLEMENTED guard", () => {

    afterEach(() => {
        globalThis.host = undefined;
    });

    test("buildHost replaces a missing host function with a stub that throws the exact message", () => {
        const effectiveHost = buildHost(createHostWithoutSha256());

        expect(() => effectiveHost.sha256("/photos/cat.jpg"))
            .toThrow(notImplementedMessage("sha256", "android"));
    });

    test("buildHost keeps installed native host functions", () => {
        const calls: string[] = [];
        const rawHost = {
            platform: "ios",
            sessionId: "session-1",
            sendMessage: () => { /* no-op */ },
            isCancelled: () => false,
            sha256: (path: string) => {
                calls.push(path);
                return "deadbeef";
            },
        } as IHost;

        const effectiveHost = buildHost(rawHost);

        expect(effectiveHost.sha256("/photos/dog.jpg")).toBe("deadbeef");
        expect(calls).toEqual(["/photos/dog.jpg"]);
    });

    test("a handler that calls an unimplemented host function fails the task with the exact message", async () => {
        globalThis.host = createHostWithoutSha256();

        //
        // Handler that reaches a host function native never installed.
        //
        registerHandler("test-needs-sha256", async (data: any, context: ITaskContext) => {
            return { hash: globalThis.host!.sha256(data.path) };
        });

        await expect(runTask("task-3", "test-needs-sha256", JSON.stringify({ path: "/photos/x.jpg" })))
            .rejects.toThrow(notImplementedMessage("sha256", "android"));
    });
});
