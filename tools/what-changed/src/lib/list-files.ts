import { execFile } from "node:child_process";

//
// Lists every file in the working tree that git would consider part of the project: tracked files
// plus untracked files that no ignore rule matches. Going through git is what gives the gate exact
// .gitignore semantics without hand-writing an ignore matcher, at the cost of requiring the project
// to be a git repository.
//
export async function listRepoFiles(rootDir: string): Promise<string[]> {
    return parseGitFileList(await runGitLsFiles(rootDir));
}

//
// True when a path's extension is one the config says to leave out. Compared case-insensitively, so a
// README.MD is treated the same as a readme.md.
//
export function isIgnoredFile(relativePath: string, ignoreExtensions: string[]): boolean {
    const lowerPath = relativePath.toLowerCase();
    for (const extension of ignoreExtensions) {
        if (lowerPath.endsWith(extension.toLowerCase())) {
            return true;
        }
    }
    return false;
}

//
// Removes every file whose extension the config says to leave out. Applied to the file list before
// anything is hashed, so an ignored file is invisible to the hash tree, to every target's decision,
// and to the changed-file listing alike.
//
export function filterIgnoredFiles(relativePaths: string[], ignoreExtensions: string[]): string[] {
    if (ignoreExtensions.length === 0) {
        return relativePaths;
    }
    return relativePaths.filter(relativePath => !isIgnoredFile(relativePath, ignoreExtensions));
}

//
// Splits the NUL-separated output of `git ls-files -z` into a sorted, de-duplicated path list.
// Exported so the parsing can be tested directly against canned byte streams, including paths that
// are awkward or impossible to create on every filesystem, without spawning a real git process.
//
export function parseGitFileList(stdout: string): string[] {
    const unique = new Set<string>();
    for (const entry of stdout.split("\0")) {
        if (entry.length > 0) {
            unique.add(entry);
        }
    }
    return Array.from(unique).sort();
}

//
// Runs `git ls-files` in the given directory and resolves with its raw NUL-separated output.
// Exported so the spawn lifecycle (stdout capture, a non-zero exit, and a missing git binary) can
// be tested on its own rather than only through listRepoFiles.
//
export function runGitLsFiles(rootDir: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        execFile(
            "git",
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            { cwd: rootDir, maxBuffer: 64 * 1024 * 1024, encoding: "utf8" },
            (error, stdout, stderr) => {
                if (error) {
                    const exitCode = (error as any).code;
                    reject(new Error(`git ls-files failed in "${rootDir}" with exit code ${exitCode}: ${stderr.trim() || error.message}`));
                    return;
                }
                resolve(stdout);
            },
        );
    });
}
