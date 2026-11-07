import { resolveInitialTheme, themeOverrideFromEnv } from "../../lib/env-theme";

describe("resolveInitialTheme", () => {

    test("uses the env override when it is a valid mode", () => {
        expect(resolveInitialTheme("light", "system")).toBe("light");
        expect(resolveInitialTheme("dark", "light")).toBe("dark");
        expect(resolveInitialTheme("system", "dark")).toBe("system");
    });

    test("falls back to the saved theme when the override is empty", () => {
        expect(resolveInitialTheme("", "dark")).toBe("dark");
        expect(resolveInitialTheme("", "system")).toBe("system");
    });

    test("falls back to the saved theme when the override is not a valid mode", () => {
        expect(resolveInitialTheme("purple", "light")).toBe("light");
        expect(resolveInitialTheme("DARK", "system")).toBe("system");
    });
});

describe("themeOverrideFromEnv", () => {

    test("returns an empty string when the build-time define is absent (as under Jest)", () => {
        expect(themeOverrideFromEnv()).toBe("");
    });
});
