import { retryOrLog } from "../../lib/retry-or-log";
import { sleep } from "../../lib/sleep";
import { log } from "../../lib/log";

// Mock sleep to avoid actual delays in tests
jest.mock("../../lib/sleep", () => ({
    sleep: jest.fn().mockResolvedValue(undefined),
}));

// Mock log to avoid console output in tests
jest.mock("../../lib/log", () => ({
    log: {
        exception: jest.fn(),
    },
}));

describe("retryOrLog", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("should return result on first attempt", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        const result = await retryOrLog(operation, "Test error");

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(1);
        expect(sleep).not.toHaveBeenCalled();
        expect(log.exception).not.toHaveBeenCalled();
    });

    test("should return result after retries", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        const result = await retryOrLog(operation, "Test error", 3, 100, 2);

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
        expect(log.exception).toHaveBeenCalledTimes(2);
    });

    test("should return undefined and log error after all retries exhausted", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await retryOrLog(operation, "Test error", 3, 100, 2);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
        expect(log.exception).toHaveBeenCalledTimes(3); // 2 retries + 1 final failure
        expect(log.exception).toHaveBeenLastCalledWith("Test error", error);
    });

    test("should use custom error message", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await retryOrLog(operation, "Custom error message", 2, 100, 2);

        expect(result).toBeUndefined();
        expect(log.exception).toHaveBeenLastCalledWith("Custom error message", error);
    });

    test("should use default maxAttempts of 3", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await retryOrLog(operation, "Test error");

        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
    });

    test("should use default waitTimeMS of 1000", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockResolvedValue("success");

        await retryOrLog(operation, "Test error", 2);

        expect(sleep).toHaveBeenCalledTimes(1);
        expect(sleep).toHaveBeenCalledWith(1000);
    });

    test("should use default waitTimeScale of 2", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        await retryOrLog(operation, "Test error", 3, 100);

        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
    });

    test("should work with custom waitTimeScale", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        await retryOrLog(operation, "Test error", 3, 100, 3);

        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 300);
    });

    test("should not sleep on last attempt", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await retryOrLog(operation, "Test error", 2, 100);

        expect(operation).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenCalledTimes(1);
        expect(log.exception).toHaveBeenCalledTimes(2); // 1 retry + 1 final failure
    });

    test("should return undefined immediately when maxAttempts is 1", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await retryOrLog(operation, "Test error", 1, 100);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
        expect(sleep).not.toHaveBeenCalled();
        expect(log.exception).toHaveBeenCalledTimes(1);
        expect(log.exception).toHaveBeenCalledWith("Test error", error);
    });

    test("should return undefined when maxAttempts is 0", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        const result = await retryOrLog(operation, "Test error", 0);

        expect(result).toBeUndefined();
        expect(operation).not.toHaveBeenCalled();
        expect(sleep).not.toHaveBeenCalled();
    });

    test("should preserve error type in log", async () => {
        class CustomError extends Error {
            constructor(message: string) {
                super(message);
                this.name = "CustomError";
            }
        }

        const customError = new CustomError("Custom error message");
        const operation = jest.fn().mockRejectedValue(customError);

        await retryOrLog(operation, "Test error", 1);

        expect(log.exception).toHaveBeenCalledWith("Test error", customError);
    });

    test("should work with different return types", async () => {
        const stringOperation = jest.fn().mockResolvedValue("string result");
        const numberOperation = jest.fn().mockResolvedValue(42);
        const objectOperation = jest.fn().mockResolvedValue({ key: "value" });

        expect(await retryOrLog(stringOperation, "Test error")).toBe("string result");
        expect(await retryOrLog(numberOperation, "Test error")).toBe(42);
        expect(await retryOrLog(objectOperation, "Test error")).toEqual({ key: "value" });
    });

    test("should handle operations that return undefined", async () => {
        const operation = jest.fn().mockResolvedValue(undefined);

        const result = await retryOrLog(operation, "Test error");

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
    });

    test("should not throw errors", async () => {
        const error = new Error("This should not be thrown");
        const operation = jest.fn().mockRejectedValue(error);

        const result = await retryOrLog(operation, "Test error", 1);

        expect(result).toBeUndefined();
        expect(log.exception).toHaveBeenCalled();
    });
});

