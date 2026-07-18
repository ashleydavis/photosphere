import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { IZorkGameInfo } from "./catalog";

// Directory containing this source file.
const MODULE_DIRECTORY = dirname(fileURLToPath(import.meta.url));

// Loads a bundled story file into an ArrayBuffer for the Z-machine.
export async function loadStoryBuffer(game: IZorkGameInfo): Promise<ArrayBuffer> {
    const storyPath = join(MODULE_DIRECTORY, "..", "stories", game.storyFileName);
    const bytes = await readFile(storyPath);
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

// Loads a story file from an explicit filesystem path.
export async function loadStoryBufferFromPath(storyPath: string): Promise<ArrayBuffer> {
    const bytes = await readFile(storyPath);
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}
