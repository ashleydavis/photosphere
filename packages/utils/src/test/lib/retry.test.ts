import { retry } from "../../lib/retry";
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
        verbose: jest.fn(),
        verboseEnabled: false,
    },
}));

describe("retry", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        jest.spyOn(console, "error").mockImplementation(() => {});
    });

    afterEach(() => {
        jest.restoreAllMocks();
    });

    test("should succeed on first attempt", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        const result = await retry(operation);

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(1);
        expect(sleep).not.toHaveBeenCalled();
    });

    test("should succeed after retries", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        const result = await retry(operation, 3, 100, 2);

        expect(result).toBe("success");
        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
    });

    test("should throw error after all retries exhausted", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(retry(operation, 3, 100, 2)).rejects.toThrow("Operation failed");

        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
        expect(console.error).toHaveBeenCalledWith("Operation failed, no more retries allowed.");
    });

    test("should use default maxAttempts of 3", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(retry(operation)).rejects.toThrow("Operation failed");

        expect(operation).toHaveBeenCalledTimes(3);
        expect(sleep).toHaveBeenCalledTimes(2);
    });

    test("should use default waitTimeMS of 1000", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockResolvedValue("success");

        await retry(operation, 2);

        expect(sleep).toHaveBeenCalledTimes(1);
        expect(sleep).toHaveBeenCalledWith(1000);
    });

    test("should use default waitTimeScale of 2", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        await retry(operation, 3, 100);

        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 200);
    });

    test("should work with custom waitTimeScale", async () => {
        const operation = jest.fn()
            .mockRejectedValueOnce(new Error("First failure"))
            .mockRejectedValueOnce(new Error("Second failure"))
            .mockResolvedValue("success");

        await retry(operation, 3, 100, 3);

        expect(sleep).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenNthCalledWith(1, 100);
        expect(sleep).toHaveBeenNthCalledWith(2, 300);
    });

    test("should not sleep on last attempt", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(retry(operation, 2, 100)).rejects.toThrow("Operation failed");

        expect(operation).toHaveBeenCalledTimes(2);
        expect(sleep).toHaveBeenCalledTimes(1);
    });

    test("should throw error immediately when maxAttempts is 1", async () => {
        const error = new Error("Operation failed");
        const operation = jest.fn().mockRejectedValue(error);

        await expect(retry(operation, 1, 100)).rejects.toThrow("Operation failed");

        expect(operation).toHaveBeenCalledTimes(1);
        expect(sleep).not.toHaveBeenCalled();
        expect(log.exception).not.toHaveBeenCalled();
        expect(console.error).toHaveBeenCalledWith("Operation failed, no more retries allowed.");
    });

    test("should throw expected error when maxAttempts is 0", async () => {
        const operation = jest.fn().mockResolvedValue("success");

        await expect(retry(operation, 0)).rejects.toThrow("Expected there to be an error!");

        expect(operation).not.toHaveBeenCalled();
        expect(sleep).not.toHaveBeenCalled();
    });

    test("should preserve error type and message", async () => {
        class CustomError extends Error {
            constructor(message: string) {
                super(message);
                this.name = "CustomError";
            }
        }

        const customError = new CustomError("Custom error message");
        const operation = jest.fn().mockRejectedValue(customError);

        await expect(retry(operation, 1)).rejects.toThrow(customError);
        await expect(retry(operation, 1)).rejects.toThrow("Custom error message");
    });

    test("should work with different return types", async () => {
        const stringOperation = jest.fn().mockResolvedValue("string result");
        const numberOperation = jest.fn().mockResolvedValue(42);
        const objectOperation = jest.fn().mockResolvedValue({ key: "value" });

        expect(await retry(stringOperation)).toBe("string result");
        expect(await retry(numberOperation)).toBe(42);
        expect(await retry(objectOperation)).toEqual({ key: "value" });
    });

    test("should handle operations that return undefined", async () => {
        const operation = jest.fn().mockResolvedValue(undefined);

        const result = await retry(operation);

        expect(result).toBeUndefined();
        expect(operation).toHaveBeenCalledTimes(1);
    });
});

