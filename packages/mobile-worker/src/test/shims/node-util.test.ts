import { promisify } from "../../shims/node-util";

//
// Unit tests for util.promisify, used by node-utils' exec wrapper at import time.
//
describe("node-util promisify shim", () => {

    test("resolves with the callback result", async () => {
        const callbackStyle = (value: number, callback: (error: unknown, result: number) => void) => {
            callback(null, value * 2);
        };
        const promised = promisify(callbackStyle);
        await expect(promised(21)).resolves.toBe(42);
    });

    test("rejects with the callback error", async () => {
        const failing = (callback: (error: unknown) => void) => {
            callback(new Error("boom"));
        };
        const promised = promisify(failing);
        await expect(promised()).rejects.toThrow("boom");
    });

    test("forwards multiple arguments to the original function", async () => {
        const add = (left: number, right: number, callback: (error: unknown, result: number) => void) => {
            callback(null, left + right);
        };
        const promised = promisify(add);
        await expect(promised(2, 3)).resolves.toBe(5);
    });
});
