import { swallowError } from "../../lib/swallow-error";
import { log } from "../../lib/log";

// Mock log to verify it's not called
jest.mock("../../lib/log", () => ({
    log: {
        exception: jest.fn(),
    },
}));

describe("swallowError", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("should return result on success", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        const result = await swallowError(operation);

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should return undefined and not log error on failure", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await swallowError(operation);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should work with different return types", async () => {
        const stringOperation = jest.fn().mockResolvedValue("string result");
        const numberOperation = jest.fn().mockResolvedValue(42);
        const objectOperation = jest.fn().mockResolvedValue({ key: "value" });

        expect(await swallowError(stringOperation)).toBe("string result");
        expect(await swallowError(numberOperation)).toBe(42);
        expect(await swallowError(objectOperation)).toEqual({ key: "value" });
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle operations that return undefined", async () => {
        const operation = jest.fn().mockResolvedValue(undefined);

        const result = await swallowError(operation);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle operations that return null", async () => {
        const operation = jest.fn().mockResolvedValue(null);

        const result = await swallowError(operation);

        expect(result).toBeNull();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle different error types without logging", async () => {
        class CustomError extends Error {
            constructor(message: string) {
                super(message);
                this.name = "CustomError";
            }
        }

        const customError = new CustomError("Custom error message");
        const operation = jest.fn().mockRejectedValue(customError);

        const result = await swallowError(operation);

        expect(result).toBeUndefined();
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle non-Error objects thrown without logging", async () => {
        const operation = jest.fn().mockRejectedValue("String error");

        const result = await swallowError(operation);

        expect(result).toBeUndefined();
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should not throw errors", async () => {
        const error = new Error("This should not be thrown");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(swallowError(operation)).resolves.toBeUndefined();
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should silently handle multiple consecutive failures", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const results = await Promise.all([
            swallowError(operation),
            swallowError(operation),
            swallowError(operation),
        ]);

        expect(results).toEqual([undefined, undefined, undefined]);
        expect(operation).toHaveBeenCalledTimes(3);
        expect(log.exception).not.toHaveBeenCalled();
    });
});

