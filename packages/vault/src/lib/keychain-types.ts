import { spawn } from "child_process";

//
// JSON envelope stored as the keychain "password" value.
// Wraps the secret type and value so both can be retrieved from a single
// keychain entry.
//
export interface IKeychainPayload {
    //
    // Caller-defined category string for the secret (e.g. "api-key").
    //
    type: string;

    //
    // The secret value as a plain string.
    //
    value: string;
}

//
// Prefix applied to every secret name stored in the OS keychain.
// Makes photosphere entries clearly identifiable in the keychain UI.
//
export const KEYCHAIN_PREFIX = "psi-";

//
// Returns the keychain account name for a given user-facing secret name
// by prepending the psi- prefix.
//
export function toKeychainName(name: string): string {
    return KEYCHAIN_PREFIX + name;
}

//
// Strips the psi- prefix from a keychain account name to obtain the
// user-facing secret name.
//
export function fromKeychainName(keychainName: string): string {
    return keychainName.slice(KEYCHAIN_PREFIX.length);
}

//
// Spawns a child process with the given arguments, resolves with trimmed
// stdout on success, or rejects with an error including stderr on non-zero exit.
//
export function runCommand(args: string[]): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        const [cmd, ...cmdArgs] = args;
        const child = spawn(cmd, cmdArgs, { stdio: ["pipe", "pipe", "pipe"] });
        const stdoutChunks: Buffer[] = [];
        const stderrChunks: Buffer[] = [];

        child.stdout.on("data", (chunk: Buffer) => {
            stdoutChunks.push(chunk);
        });

        child.stderr.on("data", (chunk: Buffer) => {
            stderrChunks.push(chunk);
        });

        child.on("close", (code: number | null) => {
            const stdout = Buffer.concat(stdoutChunks).toString("utf8").trim();
            const stderr = Buffer.concat(stderrChunks).toString("utf8").trim();
            if (code === 0) {
                resolve(stdout);
            }
            else {
                reject(new Error(`Command "${args.join(" ")}" exited with code ${code}. stderr: ${stderr}`));
            }
        });

        child.on("error", (err: Error) => {
            reject(err);
        });
    });
}
