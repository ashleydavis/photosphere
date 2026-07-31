import { spawn } from "node:child_process";

//
// Runs a command to completion with its output going straight to the terminal, and resolves with its
// exit code. A child killed by a signal resolves as 128 plus the signal number, so a Ctrl-C is never
// mistaken for success.
//
export async function runCommand(command: string[], cwd: string): Promise<number> {
    return new Promise<number>((resolve, reject) => {
        const child = spawn(command[0], command.slice(1), {
            cwd,
            stdio: "inherit",
        });

        child.on("error", err => {
            reject(new Error(`Failed to run "${command.join(" ")}" in "${cwd}": ${err.message}`));
        });

        child.on("close", (code, signal) => {
            if (signal) {
                resolve(128 + signalNumberFor(signal));
                return;
            }
            resolve(code === null ? 1 : code);
        });
    });
}

//
// Maps the signal names a child is realistically killed by to their numbers. Anything else falls back
// to 0, which still leaves a non-zero exit code because of the 128 offset.
//
export function signalNumberFor(signal: string): number {
    const numbers: Record<string, number> = {
        SIGHUP: 1,
        SIGINT: 2,
        SIGQUIT: 3,
        SIGKILL: 9,
        SIGTERM: 15,
    };
    return numbers[signal] === undefined ? 0 : numbers[signal];
}
