import { logExceptions } from "../../lib/log-exceptions";
import { setLog, log } from "../../lib/log";

describe("logExceptions", () => {
    let loggedMessages: string[] = [];
    let loggedErrors: Error[] = [];

    beforeEach(() => {
        loggedMessages = [];
        loggedErrors = [];
        
        // Set up a mock log that captures exceptions
        setLog({
            ...log,
            exception: (message: string, error: Error) => {
                loggedMessages.push(message);
                loggedErrors.push(error);
            },
        });
    });

    afterEach(() => {
        // Reset to default log
        setLog(log);
    });

    it("should log and rethrow exceptions from async functions", async () => {
        const testError = new Error("Test error");
        const fn = logExceptions(async () => {
            throw testError;
        }, "Test error message");

        await expect(fn()).rejects.toThrow("Test error");
        expect(loggedMessages).toHaveLength(1);
        expect(loggedMessages[0]).toBe("Test error message");
        expect(loggedErrors).toHaveLength(1);
        expect(loggedErrors[0]).toBe(testError);
    });

    it("should use function name in error message if no message provided", async () => {
        const testError = new Error("Test error");
        // Named function declaration preserves the name
        async function testFunction() {
            throw testError;
        }
        const fn = logExceptions(testFunction);

        await expect(fn()).rejects.toThrow("Test error");
        expect(loggedMessages).toHaveLength(1);
        expect(loggedMessages[0]).toBe("Exception in testFunction");
        expect(loggedErrors).toHaveLength(1);
    });

    it("should use 'anonymous function' if function has no name", async () => {
        const testError = new Error("Test error");
        const fn = logExceptions(async () => {
            throw testError;
        });

        await expect(fn()).rejects.toThrow("Test error");
        expect(loggedMessages).toHaveLength(1);
        expect(loggedMessages[0]).toBe("Exception in anonymous function");
    });

    it("should pass through return values when no error occurs", async () => {
        const fn = logExceptions(async () => {
            return "success";
        }, "Should not log");

        const result = await fn();
        expect(result).toBe("success");
        expect(loggedMessages).toHaveLength(0);
        expect(loggedErrors).toHaveLength(0);
    });

    it("should pass through arguments correctly", async () => {
        const fn = logExceptions(async (a: string, b: number) => {
            return `${a}-${b}`;
        }, "Should not log");

        const result = await fn("test", 42);
        expect(result).toBe("test-42");
        expect(loggedMessages).toHaveLength(0);
    });

    it("should handle non-Error exceptions by converting them to Error", async () => {
        const fn = logExceptions(async () => {
            throw "String error";
        }, "Test error message");

        await expect(fn()).rejects.toBe("String error");
        expect(loggedMessages).toHaveLength(1);
        expect(loggedErrors).toHaveLength(1);
        expect(loggedErrors[0]).toBeInstanceOf(Error);
        expect(loggedErrors[0].message).toBe("String error");
    });

    it("should preserve function signature types", async () => {
        const fn = logExceptions(async (x: number, y: string): Promise<string> => {
            return `${x}-${y}`;
        });

        const result: string = await fn(1, "test");
        expect(result).toBe("1-test");
    });
});

