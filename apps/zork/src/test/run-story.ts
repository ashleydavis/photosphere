import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ZMachine, TestIOAdapter } from "zmachine";
import { findGame, type ZorkGameId } from "../catalog";

// Result of a scripted smoke playthrough against a story file.
export interface IStorySmokeResult {
    // Captured game transcript from both windows.
    transcript: string;
    // Whether the game reached a quit state.
    hasQuit: boolean;
}

// Loads a bundled story and feeds it a scripted command list.
export async function runStorySmoke(
    gameId: ZorkGameId,
    commands: string[]
): Promise<IStorySmokeResult> {
    const game = findGame(gameId);

    if (game === undefined) {
        throw new Error(`Unknown game id: ${gameId}`);
    }

    const storyPath = join(__dirname, "..", "..", "stories", game.storyFileName);
    const bytes = readFileSync(storyPath);
    const buffer = bytes.buffer.slice(
        bytes.byteOffset,
        bytes.byteOffset + bytes.byteLength
    );

    const io = new TestIOAdapter();

    for (const command of commands) {
        io.queueLineInput(command);
    }

    // Every smoke script ends by quitting so the VM halts cleanly.
    io.queueLineInput("quit");
    io.queueLineInput("y");

    const machine = ZMachine.load(buffer, io);
    await machine.run();

    return {
        transcript: io.getFullOutput(),
        hasQuit: io.hasQuit,
    };
}

// Returns the raw bytes for a bundled story file.
export function readStoryBytes(gameId: ZorkGameId): Buffer {
    const game = findGame(gameId);

    if (game === undefined) {
        throw new Error(`Unknown game id: ${gameId}`);
    }

    const storyPath = join(__dirname, "..", "..", "stories", game.storyFileName);
    return readFileSync(storyPath);
}
