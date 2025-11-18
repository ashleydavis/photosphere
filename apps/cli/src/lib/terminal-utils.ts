//
// Utilities for handling terminal operations safely in both TTY and non-TTY environments
//

import { log } from "utils";

function clearLine(): void {
    if (process.stdout.isTTY && process.stdout.clearLine) {
        process.stdout.clearLine(0);
    }
}

function cursorTo(x: number): void {
    if (process.stdout.isTTY && process.stdout.cursorTo) {
        process.stdout.cursorTo(x);
    }
}

export function clearProgressMessage(): void {
    // Clear the current line and reset cursor position
    // Only when verbose logging is disabled (same condition as writeProgress)
    if (!log.verboseEnabled && process.stdout.isTTY) {
        clearLine();
        cursorTo(0);
    }
}

export function writeProgress(message: string): void {
    // Only write progress messages when verbose logging is disabled
    // In verbose mode, detailed logs are shown instead
    if (!log.verboseEnabled && process.stdout.isTTY) {
        clearProgressMessage();
        process.stdout.write(message);
    }
}