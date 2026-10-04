import { makeLargePayload } from "../lib/large-payload";

describe("makeLargePayload", () => {
    test("has exactly the requested length", () => {
        expect(makeLargePayload(1000).length).toBe(1000);
        expect(makeLargePayload(5 * 1024 * 1024).length).toBe(5 * 1024 * 1024);
    });

    test("includes quotes, newlines and non-ASCII characters", () => {
        const text = makeLargePayload(1000);
        expect(text).toContain("\"");
        expect(text).toContain("\n");
        expect(text).toContain("世界");
    });
});
