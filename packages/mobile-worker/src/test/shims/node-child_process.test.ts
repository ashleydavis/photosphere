import { exec, execSync, spawn, spawnSync } from "../../shims/node-child_process";

//
// Unit tests for the `child_process` shim. Subprocesses do not exist in the embedded engine, so
// every entry point must fail loudly with NOT IMPLEMENTED rather than silently doing nothing.
//
describe("node-child_process shim", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("every function throws NOT IMPLEMENTED", () => {
        expect(() => exec()).toThrow(/NOT IMPLEMENTED/);
        expect(() => execSync()).toThrow(/NOT IMPLEMENTED/);
        expect(() => spawn()).toThrow(/NOT IMPLEMENTED/);
        expect(() => spawnSync()).toThrow(/NOT IMPLEMENTED/);
    });

    test("the error names the child_process function that was called", () => {
        expect(() => exec()).toThrow(/childProcessExec"/);
        expect(() => execSync()).toThrow(/childProcessExecSync/);
        expect(() => spawn()).toThrow(/childProcessSpawn"/);
        expect(() => spawnSync()).toThrow(/childProcessSpawnSync/);
    });

    test("the error names the host platform when one is installed", () => {
        (globalThis as any).host = { platform: "android" };
        expect(() => spawn()).toThrow(/on android/);
    });

    test("the error falls back to 'mobile' when no host platform is available", () => {
        expect(() => spawn()).toThrow(/on mobile/);
    });
});
