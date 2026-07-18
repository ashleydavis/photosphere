import { findGame, resolveGameId, ZORK_GAMES } from "../catalog";

describe("ZORK_GAMES", () => {
    test("includes the three trilogy titles", () => {
        expect(ZORK_GAMES.map(game => game.id)).toEqual([
            "zork1",
            "zork2",
            "zork3",
        ]);
    });

    test("points each title at a bundled story file", () => {
        for (const game of ZORK_GAMES) {
            expect(game.storyFileName.endsWith(".z3")).toBe(true);
            expect(game.storyPath).toContain(game.storyFileName);
        }
    });
});

describe("findGame", () => {
    test("returns metadata for a known id", () => {
        expect(findGame("zork2")?.title).toBe("Zork II");
    });

    test("returns undefined for an unknown id", () => {
        expect(findGame("zork9")).toBeUndefined();
    });
});

describe("resolveGameId", () => {
    test("defaults to zork1 when input is empty", () => {
        expect(resolveGameId(undefined)).toBe("zork1");
        expect(resolveGameId("")).toBe("zork1");
        expect(resolveGameId("   ")).toBe("zork1");
    });

    test("accepts numeric and roman selectors", () => {
        expect(resolveGameId("1")).toBe("zork1");
        expect(resolveGameId("II")).toBe("zork2");
        expect(resolveGameId("3")).toBe("zork3");
    });

    test("accepts zork ids", () => {
        expect(resolveGameId("zork1")).toBe("zork1");
        expect(resolveGameId("ZORK-2")).toBe("zork2");
        expect(resolveGameId("zork3")).toBe("zork3");
    });

    test("throws for unknown values", () => {
        expect(() => resolveGameId("planetfall")).toThrow(/Unknown game/);
    });
});
