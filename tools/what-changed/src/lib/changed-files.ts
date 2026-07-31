import { PassedFileHashes } from "./cache-store";
import { MISSING_FILE_HASH } from "./file-hash";

//
// What happened to one file since the baseline was recorded.
//
export type FileChangeKind = "added" | "modified" | "deleted";

//
// One file that differs from the baseline.
//
export interface ChangedFile {
    //
    // The repository-relative path.
    //
    path: string;

    //
    // Whether the file was added, modified or deleted since the baseline.
    //
    kind: FileChangeKind;

    //
    // The file's current content hash, or an empty string for a deleted file.
    //
    hash: string;

    //
    // The file's content hash in the baseline, or an empty string for an added file.
    //
    previousHash: string;
}

//
// Compares the working tree's file hashes against the baseline recorded at the last passing run and
// returns every difference, sorted by path. Pure, so the whole comparison is testable without a disk.
//
export function diffFileHashes(current: Map<string, string>, baseline: PassedFileHashes): ChangedFile[] {
    const changes: ChangedFile[] = [];
    const present = presentFiles(current);

    for (const [relativePath, hash] of present) {
        const previousHash = baseline[relativePath];
        if (previousHash === undefined) {
            changes.push({ path: relativePath, kind: "added", hash, previousHash: "" });
        }
        else if (previousHash !== hash) {
            changes.push({ path: relativePath, kind: "modified", hash, previousHash });
        }
    }

    for (const relativePath of Object.keys(baseline)) {
        if (!present.has(relativePath)) {
            changes.push({ path: relativePath, kind: "deleted", hash: "", previousHash: baseline[relativePath] });
        }
    }

    changes.sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
    return changes;
}

//
// Drops the files that are listed but not actually on disk. git lists a tracked file even after it has
// been deleted from the working tree, and such a file hashes to MISSING_FILE_HASH. Treating it as
// present would report a deletion as a modification to the literal text "<missing>".
//
export function presentFiles(current: Map<string, string>): Map<string, string> {
    const present = new Map<string, string>();
    for (const [relativePath, hash] of current) {
        if (hash !== MISSING_FILE_HASH) {
            present.set(relativePath, hash);
        }
    }
    return present;
}

//
// Turns a map of path to hash into the plain object shape that is stored as the baseline, leaving out
// any file that is not actually on disk so the baseline only ever holds real content hashes.
//
export function toPassedFileHashes(current: Map<string, string>): PassedFileHashes {
    const passed: PassedFileHashes = {};
    for (const [relativePath, hash] of presentFiles(current)) {
        passed[relativePath] = hash;
    }
    return passed;
}

//
// Renders the changed files as the lines the CLI prints: a one-letter kind, the short hash, and the
// path. A deleted file shows the hash it used to have, since there is no current one.
//
export function formatChangedFiles(changes: ChangedFile[]): string[] {
    return changes.map(change => {
        const marker = change.kind === "added" ? "A" : change.kind === "modified" ? "M" : "D";
        const shownHash = change.kind === "deleted" ? change.previousHash : change.hash;
        return `  ${marker}  ${shownHash.slice(0, 16)}  ${change.path}`;
    });
}
