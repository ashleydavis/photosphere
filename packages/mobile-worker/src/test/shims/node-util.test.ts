import { promisify, inherits, debuglog, inspect } from "../../shims/node-util";

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

    test("inherits links the prototype chain and records super_ (the cipher-base pattern)", () => {
        function BaseConstructor(this: any): void { /* base */ }
        (BaseConstructor as any).prototype.describe = () => "from base";

        function DerivedConstructor(this: any): void { /* derived */ }
        inherits(DerivedConstructor, BaseConstructor);

        expect((DerivedConstructor as any).super_).toBe(BaseConstructor);
        expect(new (DerivedConstructor as any)().describe()).toBe("from base");
    });

    test("debuglog returns a callable no-op so debug logging is disabled", () => {
        const logger = debuglog();
        expect(typeof logger).toBe("function");
        expect(logger("anything", 1, 2)).toBeUndefined();
    });

    test("inspect returns strings unchanged and JSON-encodes everything else", () => {
        expect(inspect("already a string")).toBe("already a string");
        expect(inspect({ size: 5 })).toBe('{"size":5}');
        expect(inspect([1, 2])).toBe("[1,2]");
    });
});
