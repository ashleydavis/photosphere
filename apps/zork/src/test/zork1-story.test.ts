import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ZMachine, TestIOAdapter } from "zmachine";
import { findGame } from "../catalog";

describe("Zork I story file", () => {
    test("is a version 3 Z-machine story", () => {
        const game = findGame("zork1");

        expect(game).toBeDefined();

        const storyPath = join(__dirname, "..", "..", "stories", game!.storyFileName);
        const bytes = readFileSync(storyPath);

        expect(bytes[0]).toBe(3);
        expect(bytes.byteLength).toBeGreaterThan(50_000);
    });

    test("plays the opening mailbox puzzle", async () => {
        const game = findGame("zork1");
        const storyPath = join(__dirname, "..", "..", "stories", game!.storyFileName);
        const bytes = readFileSync(storyPath);
        const buffer = bytes.buffer.slice(
            bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength
        );

        const io = new TestIOAdapter();
        io.queueLineInput("open mailbox");
        io.queueLineInput("take leaflet");
        io.queueLineInput("read leaflet");
        io.queueLineInput("quit");
        io.queueLineInput("y");

        const machine = ZMachine.load(buffer, io);
        await machine.run();

        const transcript = io.getFullOutput();

        expect(transcript).toContain("West of House");
        expect(transcript).toContain("Opening the small mailbox reveals a leaflet");
        expect(transcript).toContain("WELCOME TO ZORK");
        expect(io.hasQuit).toBe(true);
    });
});

describe("Zork II and III story files", () => {
    test("bundle version 3 story files for II and III", () => {
        for (const id of ["zork2", "zork3"] as const) {
            const game = findGame(id);
            const storyPath = join(__dirname, "..", "..", "stories", game!.storyFileName);
            const bytes = readFileSync(storyPath);

            expect(bytes[0]).toBe(3);
            expect(bytes.byteLength).toBeGreaterThan(50_000);
        }
    });
});
