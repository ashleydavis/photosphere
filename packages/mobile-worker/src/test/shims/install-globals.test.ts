import { installGlobals, installTimers, installTextCodecs, installCrypto, installPerformance } from "../../lib/install-globals";

//
// Unit tests for the global installers. They are tested against a fake scope object so the real
// global environment is not mutated and the timer queue (which only installs where setTimeout is
// absent) can be exercised deterministically.
//
describe("install-globals", () => {

    describe("installTimers", () => {

        test("fires the earliest-delay timer first via __pumpTimers", () => {
            const scope: any = {};
            installTimers(scope);

            const fired: string[] = [];
            scope.setTimeout(() => fired.push("late"), 100);
            scope.setTimeout(() => fired.push("early"), 10);
            scope.setTimeout(() => fired.push("middle"), 50);

            expect(scope.__pumpTimers()).toBe(true);
            expect(scope.__pumpTimers()).toBe(true);
            expect(scope.__pumpTimers()).toBe(true);
            expect(scope.__pumpTimers()).toBe(false);

            expect(fired).toEqual(["early", "middle", "late"]);
        });

        test("clearTimeout removes a pending timer before it fires", () => {
            const scope: any = {};
            installTimers(scope);

            const fired: string[] = [];
            const id = scope.setTimeout(() => fired.push("x"), 5);
            scope.clearTimeout(id);

            expect(scope.__pumpTimers()).toBe(false);
            expect(fired).toEqual([]);
        });

        test("forwards extra arguments to the callback", () => {
            const scope: any = {};
            installTimers(scope);
            let received: number | undefined;
            scope.setTimeout((value: number) => { received = value; }, 0, 99);
            scope.__pumpTimers();
            expect(received).toBe(99);
        });

        test("does nothing where a native setTimeout already exists", () => {
            const existing = () => 0;
            const scope: any = { setTimeout: existing };
            installTimers(scope);
            expect(scope.setTimeout).toBe(existing);
            expect(scope.__pumpTimers).toBeUndefined();
        });
    });

    describe("installTextCodecs", () => {

        test("TextEncoder/TextDecoder round-trip UTF-8 including multibyte", () => {
            const scope: any = {};
            installTextCodecs(scope);
            const encoded = new scope.TextEncoder().encode("héllo 世界");
            expect(encoded instanceof Uint8Array).toBe(true);
            expect(new scope.TextDecoder().decode(encoded)).toBe("héllo 世界");
        });

        test("TextDecoder.decode of empty/undefined input returns empty string", () => {
            const scope: any = {};
            installTextCodecs(scope);
            expect(new scope.TextDecoder().decode()).toBe("");
        });

        test("atob/btoa round-trip", () => {
            const scope: any = {};
            installTextCodecs(scope);
            expect(scope.atob(scope.btoa("hello"))).toBe("hello");
        });
    });

    describe("installCrypto", () => {

        test("fills a Uint8Array's bytes with values in range", () => {
            const scope: any = {};
            installCrypto(scope);
            const array = new Uint8Array(16);
            const returned = scope.crypto.getRandomValues(array);
            expect(returned).toBe(array);
            expect(array.every((value: number) => value >= 0 && value <= 255)).toBe(true);
        });

        test("does not replace an existing crypto.getRandomValues", () => {
            const existing = (array: any) => array;
            const scope: any = { crypto: { getRandomValues: existing } };
            installCrypto(scope);
            expect(scope.crypto.getRandomValues).toBe(existing);
        });
    });

    describe("installPerformance", () => {

        test("provides a numeric now()", () => {
            const scope: any = {};
            installPerformance(scope);
            expect(typeof scope.performance.now()).toBe("number");
        });

        test("does not replace an existing performance.now", () => {
            const existing = () => 42;
            const scope: any = { performance: { now: existing } };
            installPerformance(scope);
            expect(scope.performance.now).toBe(existing);
        });
    });

    describe("installGlobals", () => {

        test("installs Buffer, process, codecs and timers on a fresh scope", () => {
            const scope: any = {};
            installGlobals(scope);

            expect(typeof scope.Buffer).toBe("function");
            expect(scope.process.env).toEqual({});
            expect(scope.process.platform).toBe("android");
            expect(typeof scope.process.nextTick).toBe("function");
            expect(scope.process.cwd()).toBe("");
            expect(typeof scope.TextDecoder).toBe("function");
            expect(typeof scope.setTimeout).toBe("function");
        });

        test("does not overwrite an existing Buffer/process", () => {
            const existingBuffer = function existingBuffer() {};
            const existingProcess = { env: { KEEP: "1" } };
            const scope: any = { Buffer: existingBuffer, process: existingProcess };
            installGlobals(scope);
            expect(scope.Buffer).toBe(existingBuffer);
            expect(scope.process).toBe(existingProcess);
        });
    });
});
