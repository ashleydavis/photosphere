//
// Utilities for handling terminal operations safely in both TTY and non-TTY environments
//

export function clearLine(): void {
    if (process.stdout.isTTY && process.stdout.clearLine) {
        process.stdout.clearLine(0);
    }
}

export function cursorTo(x: number): void {
    if (process.stdout.isTTY && process.stdout.cursorTo) {
        process.stdout.cursorTo(x);
    }
}

export function clearProgressMessage(): void {
    // Clear the current line and reset cursor position
    clearLine();
    cursorTo(0);
}

export function writeProgress(message: string): void {
    // Only write progress messages in TTY environments
    // In CI/non-TTY environments, skip progress updates entirely
    if (process.stdout.isTTY) {
        clearProgressMessage();
        process.stdout.write(message);
    }
}