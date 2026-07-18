import { readStoryBytes, runStorySmoke } from "./run-story";

describe("Zork II smoke", () => {
    test("story file is a non-trivial version 3 image", () => {
        const bytes = readStoryBytes("zork2");

        expect(bytes[0]).toBe(3);
        expect(bytes.byteLength).toBeGreaterThan(50_000);
    });

    test("boots inside the barrow with sword and lantern", async () => {
        const result = await runStorySmoke("zork2", ["look"]);

        expect(result.transcript).toContain("ZORK II: The Wizard of Frobozz");
        expect(result.transcript).toContain("Inside the Barrow");
        expect(result.transcript).toContain("sword of Elvish workmanship");
        expect(result.transcript).toContain("brass lantern");
        expect(result.hasQuit).toBe(true);
    });

    test("takes gear, lights the lamp, and enters the narrow tunnel", async () => {
        const result = await runStorySmoke("zork2", [
            "take all",
            "turn on lamp",
            "south",
            "look",
            "inventory",
        ]);

        expect(result.transcript).toContain("Taken.");
        expect(result.transcript).toContain("The lamp is now on.");
        expect(result.transcript).toContain("Narrow Tunnel");
        expect(result.transcript).toContain("wide cavern");
        expect(result.transcript).toContain("A lamp (providing light)");
        expect(result.transcript).toContain("elvish sword");
        expect(result.hasQuit).toBe(true);
    });

    test("crosses the foot bridge and meets the Wizard of Frobozz", async () => {
        const result = await runStorySmoke("zork2", [
            "take all",
            "turn on lamp",
            "south",
            "south",
            "score",
        ]);

        expect(result.transcript).toContain("Foot Bridge");
        expect(result.transcript).toContain("Wizard");
        expect(result.transcript).toMatch(/Frobozz|wand|Fear!/i);
        expect(result.transcript).toContain("total of 400 points");
        expect(result.transcript).toContain("Beginner");
        expect(result.hasQuit).toBe(true);
    });
});
