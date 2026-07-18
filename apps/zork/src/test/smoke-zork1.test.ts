import { readStoryBytes, runStorySmoke } from "./run-story";

describe("Zork I smoke", () => {
    test("story file is a non-trivial version 3 image", () => {
        const bytes = readStoryBytes("zork1");

        expect(bytes[0]).toBe(3);
        expect(bytes.byteLength).toBeGreaterThan(50_000);
    });

    test("boots to West of House and identifies itself", async () => {
        const result = await runStorySmoke("zork1", ["look"]);

        expect(result.transcript).toContain("ZORK I: The Great Underground Empire");
        expect(result.transcript).toContain("West of House");
        expect(result.transcript).toContain("small mailbox");
        expect(result.hasQuit).toBe(true);
    });

    test("completes the mailbox and leaflet opening", async () => {
        const result = await runStorySmoke("zork1", [
            "open mailbox",
            "take leaflet",
            "read leaflet",
        ]);

        expect(result.transcript).toContain(
            "Opening the small mailbox reveals a leaflet"
        );
        expect(result.transcript).toContain("Taken.");
        expect(result.transcript).toContain("WELCOME TO ZORK");
        expect(result.hasQuit).toBe(true);
    });

    test("enters the white house through the rear window", async () => {
        const result = await runStorySmoke("zork1", [
            "south",
            "east",
            "open window",
            "enter",
            "look",
        ]);

        expect(result.transcript).toContain("South of House");
        expect(result.transcript).toContain("Behind House");
        expect(result.transcript).toContain(
            "open the window far enough to allow entry"
        );
        expect(result.transcript).toContain("Kitchen");
        expect(result.hasQuit).toBe(true);
    });

    test("reaches the cellar with lamp and sword", async () => {
        const result = await runStorySmoke("zork1", [
            "south",
            "east",
            "open window",
            "enter",
            "west",
            "take lamp",
            "take sword",
            "move rug",
            "open trap",
            "turn on lamp",
            "down",
            "look",
            "inventory",
        ]);

        expect(result.transcript).toContain("Living Room");
        expect(result.transcript).toContain("revealing the dusty cover of a closed trap door");
        expect(result.transcript).toContain("rickety staircase descending into darkness");
        expect(result.transcript).toContain("The brass lantern is now on.");
        expect(result.transcript).toContain("Cellar");
        expect(result.transcript).toContain("brass lantern (providing light)");
        expect(result.transcript).toContain("A sword");
        expect(result.hasQuit).toBe(true);
    });

    test("fights the troll and earns Amateur Adventurer rank", async () => {
        // Combat text is randomized; keep swinging until the troll is gone.
        const result = await runStorySmoke("zork1", [
            "south",
            "east",
            "open window",
            "enter",
            "west",
            "take lamp",
            "take sword",
            "move rug",
            "open trap",
            "turn on lamp",
            "down",
            "north",
            "kill troll with sword",
            "kill troll with sword",
            "kill troll with sword",
            "kill troll with sword",
            "east",
            "score",
        ]);

        expect(result.transcript).toContain("The Troll Room");
        expect(result.transcript).toContain("nasty-looking troll");
        expect(result.transcript).toMatch(
            /knocks out the troll|disarmed|fatal|strokes|troll is slain|killing blow|axe/i
        );
        expect(result.transcript).toContain("East-West Passage");
        expect(result.transcript).toContain("total of 350 points");
        expect(result.transcript).toContain("Amateur Adventurer");
        expect(result.hasQuit).toBe(true);
    });

    test("collects the gallery painting treasure", async () => {
        const result = await runStorySmoke("zork1", [
            "south",
            "east",
            "open window",
            "enter",
            "west",
            "take lamp",
            "take sword",
            "move rug",
            "open trap",
            "turn on lamp",
            "down",
            "south",
            "east",
            "take painting",
            "inventory",
            "score",
        ]);

        expect(result.transcript).toContain("East of Chasm");
        expect(result.transcript).toContain("Gallery");
        expect(result.transcript).toContain("painting of unparalleled beauty");
        expect(result.transcript).toContain("Taken.");
        expect(result.transcript).toContain("A painting");
        expect(result.transcript).toContain("Amateur Adventurer");
        expect(result.hasQuit).toBe(true);
    });
});
