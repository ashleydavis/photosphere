import { readStoryBytes, runStorySmoke } from "./run-story";

describe("Zork III smoke", () => {
    test("story file is a non-trivial version 3 image", () => {
        const bytes = readStoryBytes("zork3");

        expect(bytes[0]).toBe(3);
        expect(bytes.byteLength).toBeGreaterThan(50_000);
    });

    test("boots with the Dungeon Master dream and Endless Stair", async () => {
        const result = await runStorySmoke("zork3", ["look"]);

        expect(result.transcript).toContain("ZORK III: The Dungeon Master");
        expect(result.transcript).toContain("final test, my friend");
        expect(result.transcript).toContain("Endless Stair");
        expect(result.transcript).toContain("brass lantern");
        expect(result.hasQuit).toBe(true);
    });

    test("lights the lamp and reaches the junction with the sword in the stone", async () => {
        const result = await runStorySmoke("zork3", [
            "take lamp",
            "turn on lamp",
            "south",
            "look",
            "inventory",
        ]);

        expect(result.transcript).toContain("Taken.");
        expect(result.transcript).toContain("The lamp is now on.");
        expect(result.transcript).toContain("Junction");
        expect(result.transcript).toContain("great rock");
        expect(result.transcript).toContain("Elvish sword");
        expect(result.transcript).toContain("A lamp (providing light)");
        expect(result.hasQuit).toBe(true);
    });

    test("reports potential score and blocks the endless stairs", async () => {
        const result = await runStorySmoke("zork3", [
            "take lamp",
            "turn on lamp",
            "north",
            "score",
        ]);

        expect(result.transcript).toContain("The stairs are endless.");
        expect(result.transcript).toContain("possible 7");
        expect(result.hasQuit).toBe(true);
    });
});
