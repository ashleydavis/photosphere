import * as readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { writeFile, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
    CursorPosition,
    IOAdapter,
    ReadLineResult,
} from "zmachine";

// Terminal I/O adapter that connects the Z-machine to stdin/stdout.
export class TerminalIO implements IOAdapter {
    // Readline interface used for line input.
    private readonly terminal: readline.Interface;

    // Optional absolute path used for save/restore.
    private readonly savePath: string;

    // Whether the game has requested quit.
    private quitRequested: boolean;

    // Current upper-window line budget (status area).
    private upperWindowLines: number;

    // Active output window (0 lower, 1 upper).
    private currentWindow: number;

    // Creates a terminal adapter and optional save file location.
    constructor(saveFileName: string) {
        this.terminal = readline.createInterface({ input, output });
        this.savePath = join(homedir(), saveFileName);
        this.quitRequested = false;
        this.upperWindowLines = 0;
        this.currentWindow = 0;
    }

    // Initializes adapter state for the given Z-machine version.
    initialize(_version: number): void {
        this.quitRequested = false;
        this.upperWindowLines = 0;
        this.currentWindow = 0;
    }

    // Writes text without a trailing newline.
    print(text: string): void {
        if (this.currentWindow === 1) {
            return;
        }

        output.write(text);
    }

    // Writes text followed by a newline.
    printLine(text: string): void {
        if (this.currentWindow === 1) {
            return;
        }

        output.write(text + "\n");
    }

    // Writes a bare newline.
    newLine(): void {
        if (this.currentWindow === 1) {
            return;
        }

        output.write("\n");
    }

    // Reads a line of player input from the terminal.
    async readLine(maxLength: number, _timeout: number | undefined): Promise<ReadLineResult> {
        const answer = await this.terminal.question("");
        const trimmed = answer.slice(0, maxLength);

        return {
            text: trimmed,
            terminator: 13,
        };
    }

    // Reads a single character, used for Y/N prompts.
    async readChar(_timeout: number | undefined): Promise<number> {
        const answer = await this.terminal.question("");

        if (answer.length === 0) {
            return 13;
        }

        return answer.charCodeAt(0) & 0xff;
    }

    // Updates the ANSI status line at the top of the terminal.
    showStatusLine(
        location: string,
        score: number,
        turns: number,
        isTime: boolean
    ): void {
        const right = isTime
            ? `Time: ${score}:${turns.toString().padStart(2, "0")}`
            : `Score: ${score}  Moves: ${turns}`;
        const width = output.columns || 80;
        const padding = Math.max(1, width - location.length - right.length);
        const line = `${location}${" ".repeat(padding)}${right}`;

        output.write(`\x1b[s\x1b[1;1H\x1b[7m${line.slice(0, width)}\x1b[0m\x1b[u`);
    }

    // Selects the active output window.
    setWindow(window: number): void {
        this.currentWindow = window;
    }

    // Splits off an upper status window.
    splitWindow(lines: number): void {
        this.upperWindowLines = lines;
    }

    // Clears a window; -1 unsplits and clears.
    eraseWindow(window: number): void {
        if (window < 0) {
            output.write("\x1b[2J\x1b[H");
            this.upperWindowLines = 0;
            this.currentWindow = 0;
            return;
        }

        if (window === 0) {
            output.write("\x1b[2J\x1b[H");
        }
    }

    // No-op cursor placement for the dumb terminal.
    setCursor(_line: number, _column: number): void {
        return;
    }

    // Returns a dummy cursor position.
    getCursor(): CursorPosition {
        return {
            line: 1,
            column: 1,
        };
    }

    // No-op line erase for the dumb terminal.
    eraseLine(): void {
        return;
    }

    // Ignores styled output in the plain terminal.
    setTextStyle(_style: number): void {
        return;
    }

    // Buffering is always on for stdout.
    setBufferMode(_mode: boolean): void {
        return;
    }

    // Reports buffering as enabled.
    getBufferMode(): boolean {
        return true;
    }

    // Saves Quetzal data to the player's home directory.
    async save(data: Uint8Array): Promise<boolean> {
        await writeFile(this.savePath, data);
        output.write(`\n[Saved to ${this.savePath}]\n`);
        return true;
    }

    // Restores Quetzal data from the player's home directory.
    async restore(): Promise<Uint8Array | null> {
        try {
            const data = await readFile(this.savePath);
            output.write(`\n[Restored from ${this.savePath}]\n`);
            return new Uint8Array(data);
        }
        catch {
            output.write("\n[No save file found.]\n");
            return null;
        }
    }

    // Marks the session as finished and closes readline.
    quit(): void {
        this.quitRequested = true;
        this.terminal.close();
    }

    // Clears the screen for a restart.
    restart(): void {
        output.write("\x1b[2J\x1b[H");
    }

    // Story verification always succeeds for local files.
    verify(): boolean {
        return true;
    }

    // Returns whether quit has been requested.
    hasQuit(): boolean {
        return this.quitRequested;
    }

    // Closes the readline interface if still open.
    close(): void {
        this.terminal.close();
    }
}
