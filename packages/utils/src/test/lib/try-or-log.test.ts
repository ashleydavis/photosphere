import { tryOrLog } from "../../lib/try-or-log";
import { log } from "../../lib/log";

// Mock log to avoid console output in tests
jest.mock("../../lib/log", () => ({
    log: {
        exception: jest.fn(),
    },
}));

describe("tryOrLog", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("should return result on success", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        const result = await tryOrLog(operation);

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should return undefined and log error on failure", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await tryOrLog(operation);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).toHaveBeenCalledTimes(1);
        expect(log.exception).toHaveBeenCalledWith("Operation failed", error);
    });

    test("should use custom error message", async () => {
        const error = new Error("Something went wrong");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await tryOrLog(operation, "Custom error message");

        expect(result).toBeUndefined();
        expect(log.exception).toHaveBeenCalledWith("Custom error message", error);
    });

    test("should work with different return types", async () => {
        const stringOperation = jest.fn().mockResolvedValue("string result");
        const numberOperation = jest.fn().mockResolvedValue(42);
        const objectOperation = jest.fn().mockResolvedValue({ key: "value" });

        expect(await tryOrLog(stringOperation)).toBe("string result");
        expect(await tryOrLog(numberOperation)).toBe(42);
        expect(await tryOrLog(objectOperation)).toEqual({ key: "value" });
    });

    test("should handle operations that return undefined", async () => {
        const operation = jest.fn().mockResolvedValue(undefined);

        const result = await tryOrLog(operation);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle operations that return null", async () => {
        const operation = jest.fn().mockResolvedValue(null);

        const result = await tryOrLog(operation);

        expect(result).toBeNull();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should handle different error types", async () => {
        class CustomError extends Error {
            constructor(message: string) {
                super(message);
                this.name = "CustomError";
            }
        }

        const customError = new CustomError("Custom error message");
        const operation = jest.fn().mockRejectedValue(customError);

        const result = await tryOrLog(operation);

        expect(result).toBeUndefined();
        expect(log.exception).toHaveBeenCalledWith("Operation failed", customError);
    });

    test("should handle non-Error objects thrown", async () => {
        const operation = jest.fn().mockRejectedValue("String error");

        const result = await tryOrLog(operation);

        expect(result).toBeUndefined();
        expect(log.exception).toHaveBeenCalledTimes(1);
        // log.exception should still be called even with non-Error objects
    });

    test("should not throw errors", async () => {
        const error = new Error("This should not be thrown");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(tryOrLog(operation)).resolves.toBeUndefined();
        expect(log.exception).toHaveBeenCalled();
    });
});

