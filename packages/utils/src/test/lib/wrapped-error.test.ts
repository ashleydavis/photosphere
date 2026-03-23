import { WrappedError, formatErrorChain } from "../../lib/wrapped-error";

describe("WrappedError", () => {
    test("should set message", () => {
        const cause = new Error("original");
        const error = new WrappedError("context", { cause });
        expect(error.message).toBe("context");
    });

    test("should set cause on the standard cause property", () => {
        const cause = new Error("original");
        const error = new WrappedError("context", { cause });
        expect((error as any).cause).toBe(cause);
    });

    test("should be an instance of Error", () => {
        const error = new WrappedError("context", { cause: new Error("original") });
        expect(error).toBeInstanceOf(Error);
    });

    test("should be an instance of WrappedError", () => {
        const error = new WrappedError("context", { cause: new Error("original") });
        expect(error).toBeInstanceOf(WrappedError);
    });
});

describe("formatErrorChain", () => {
    test("should format a single error", () => {
        const error = new Error("something went wrong");
        const result = formatErrorChain(error);
        expect(result).toContain("something went wrong");
    });

    test("should include cause in output", () => {
        const cause = new Error("root cause");
        const error = new WrappedError("outer", { cause });
        const result = formatErrorChain(error);
        expect(result).toContain("outer");
        expect(result).toContain("root cause");
        expect(result).toContain("Caused by:");
    });

    test("should traverse multiple levels of cause chain", () => {
        const root = new Error("root");
        const middle = new WrappedError("middle", { cause: root });
        const outer = new WrappedError("outer", { cause: middle });
        const result = formatErrorChain(outer);
        expect(result).toContain("outer");
        expect(result).toContain("middle");
        expect(result).toContain("root");
        const causedByCount = (result.match(/Caused by:/g) || []).length;
        expect(causedByCount).toBe(2);
    });

    test("should not append Caused by: after the last error", () => {
        const cause = new Error("root cause");
        const error = new WrappedError("outer", { cause });
        const result = formatErrorChain(error);
        expect(result.endsWith("Caused by:")).toBe(false);
        expect(result.trimEnd().endsWith("Caused by:")).toBe(false);
    });

    test("should use stack when available", () => {
        const error = new Error("with stack");
        const result = formatErrorChain(error);
        expect(result).toBe(error.stack);
    });

    test("should fall back to message when stack is absent", () => {
        const error: any = { message: "no stack here", cause: undefined };
        const result = formatErrorChain(error);
        expect(result).toContain("no stack here");
    });
});
