import * as fs from 'fs/promises';
import * as fsSync from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'crypto';
import { parse as tomlParse, stringify as tomlStringify } from 'smol-toml';

//
// Ensures that the directory exists. If the directory structure does not exist, it is created.
// Like fs-extra's ensureDir, but using native fs.promises.
//
export async function ensureDir(dirPath: string): Promise<void> {
    try {
        await fs.mkdir(dirPath, { recursive: true });
    } catch (error: any) {
        // With recursive: true, mkdir should not throw EEXIST if directory exists
        // But if it does, or if path exists as a file, handle it
        if (error.code === 'EEXIST') {
            // Verify it's actually a directory
            const stats = await fs.stat(dirPath);
            if (!stats.isDirectory()) {
                throw new Error(`Path exists but is not a directory: ${dirPath}`);
            }
        } else {
            throw error;
        }
    }
}

//
// Ensures that the directory containing the file exists. If the directory structure does not exist, it is created.
//
export async function ensureFileDir(filePath: string): Promise<void> {
    const dirPath = path.dirname(filePath);
    return ensureDir(dirPath);
}

//
// Checks if a path exists (file or directory).
//
export async function pathExists(filePath: string): Promise<boolean> {
    try {
        await fs.access(filePath);
        return true;
    } catch {
        return false;
    }
}

//
// Removes a file or directory. Works like fs-extra's remove.
//
export async function remove(targetPath: string): Promise<void> {
    try {
        const stats = await fs.stat(targetPath);
        
        if (stats.isDirectory()) {
            // Use fs.rm with recursive option (preferred over rmdir)
            await fs.rm(targetPath, { recursive: true, force: true });
        } else {
            await fs.unlink(targetPath);
        }
    } catch (error: any) {
        // If file/directory doesn't exist, that's fine (like fs-extra behavior)
        if (error.code !== 'ENOENT') {
            throw error;
        }
    }
}

//
// Outputs a file ensuring the directory exists. Like fs-extra's outputFile.
// The write is atomic: data is written to a unique temporary file in the same
// directory and then renamed into place. Because rename is atomic, a concurrent
// reader never sees a half-written file and two concurrent writers cannot
// interleave their bytes into a corrupt result (the last rename wins, and every
// intermediate state is a complete file). The temp name uses a fresh UUID so
// overlapping writes to the same target never share a temp file.
//
export async function outputFile(filePath: string, data: string | Buffer, options?: { encoding?: BufferEncoding; mode?: number }): Promise<void> {
    await ensureFileDir(filePath);
    const tempPath = `${filePath}.tmp-${randomUUID()}`;
    await fs.writeFile(tempPath, data, options);
    await fs.rename(tempPath, filePath);
}

//
// Reads a JSON file and parses it. Like fs-extra's readJson.
//
export async function readJson<T = any>(filePath: string, options?: { encoding?: BufferEncoding; flag?: string }): Promise<T> {
    const data = await fs.readFile(filePath, options || { encoding: 'utf8' });
    return JSON.parse(data.toString());
}

//
// Reads a TOML file and parses it.
//
export async function readToml<T = any>(filePath: string): Promise<T> {
    const data = await fs.readFile(filePath, { encoding: 'utf8' });
    return tomlParse(data.toString()) as T;
}

//
// Writes an object to a TOML file, creating parent directories as needed.
//
export async function writeToml(filePath: string, object: Record<string, any>): Promise<void> {
    const tomlString = tomlStringify(object);
    await outputFile(filePath, tomlString, { encoding: 'utf8' });
}

//
// Writes an object to a JSON file. Like fs-extra's writeJson.
//
export async function writeJson(filePath: string, object: any, options?: { encoding?: BufferEncoding; spaces?: number | string; mode?: number }): Promise<void> {
    const jsonString = JSON.stringify(object, null, options?.spaces);
    await outputFile(filePath, jsonString, { encoding: options?.encoding || 'utf8', mode: options?.mode });
}

//
// Reads a file's raw text, or undefined when it does not exist yet.
//
async function readRawFile(filePath: string): Promise<string | undefined> {
    if (!await pathExists(filePath)) {
        return undefined;
    }
    return await fs.readFile(filePath, { encoding: 'utf8' });
}

//
// A cheap fingerprint of a file used to detect whether it changed between our read and our write
// without re-reading its contents. Undefined when the file does not exist. It uses only fields
// available on every platform we target (Node on Linux/macOS/Windows and the mobile stat shim):
// size and last-modified time. It deliberately avoids inode/nanosecond fields, which are absent on
// mobile and unreliable on Windows. The trade-off is that two writes producing an identical size in
// the same millisecond would not be told apart, which the optimistic retry accepts.
//
interface IFileFingerprint {
    // Last-modified time in milliseconds since the epoch.
    modifiedMs: number;

    // File size in bytes.
    size: number;
}

//
// Returns a fingerprint of the file at the given path, or undefined when it does not exist.
//
async function fileFingerprint(filePath: string): Promise<IFileFingerprint | undefined> {
    if (!await pathExists(filePath)) {
        return undefined;
    }
    const stats = await fs.stat(filePath);
    return { modifiedMs: stats.mtime.getTime(), size: stats.size };
}

//
// Reports whether two fingerprints describe the same file state. Two absent files (both
// undefined) count as unchanged.
//
function fingerprintsMatch(before: IFileFingerprint | undefined, after: IFileFingerprint | undefined): boolean {
    if (before === undefined || after === undefined) {
        return before === after;
    }
    return before.modifiedMs === after.modifiedMs && before.size === after.size;
}

//
// Updates a file as an optimistic read-modify-write, with no cross-call locking or shared state.
// It fingerprints the file, reads and parses the current text (or uses `fallback` when absent),
// applies `mutator`, and writes the result to a temp file. Just before the atomic move it
// re-fingerprints the file (a cheap stat, not a second full read): if it changed since we read
// it, another writer got in first, so it discards the temp and retries from the fresh contents.
// After `retries` such conflicts it throws. This makes concurrent updates safe without serializing
// them. The fingerprint is taken before the read so a change during the read is caught as a
// conflict rather than silently overwriting the other writer.
//
export async function updateFileOptimistic<ContentType>(filePath: string, fallback: ContentType, mutator: (current: ContentType) => ContentType, parse: (raw: string) => ContentType, serialize: (value: ContentType) => string, retries: number): Promise<void> {
    for (let attempt = 0; attempt <= retries; attempt += 1) {
        const fingerprintBefore = await fileFingerprint(filePath);
        const originalRaw = await readRawFile(filePath);
        const current = originalRaw === undefined ? fallback : parse(originalRaw);
        const updatedRaw = serialize(mutator(current));

        await ensureFileDir(filePath);
        const tempPath = `${filePath}.tmp-${randomUUID()}`;
        await fs.writeFile(tempPath, updatedRaw, { encoding: 'utf8' });

        // If the file is unchanged since we read it, publish our version atomically.
        // Otherwise a concurrent writer won; drop the temp and retry from fresh contents.
        const fingerprintAfter = await fileFingerprint(filePath);
        if (fingerprintsMatch(fingerprintBefore, fingerprintAfter)) {
            await fs.rename(tempPath, filePath);
            return;
        }
        await fs.rm(tempPath, { force: true });
    }
    throw new Error(`Failed to update ${filePath}: the file kept changing under concurrent writers after ${retries} retries.`);
}

//
// Updates a TOML file as an optimistic read-modify-write: reads the current parsed contents
// (or `fallback` when the file does not exist yet), passes them to `mutator`, and writes the
// returned value back atomically. If another writer changed the file first, it reloads and
// re-applies the mutator, up to `retries` times (default 3) before throwing.
//
export async function updateToml<ContentType extends Record<string, any>>(filePath: string, fallback: ContentType, mutator: (current: ContentType) => ContentType, retries: number = 3): Promise<void> {
    await updateFileOptimistic(filePath, fallback, mutator, raw => tomlParse(raw) as ContentType, value => tomlStringify(value), retries);
}

//
// Updates a JSON file as an optimistic read-modify-write. Same semantics as updateToml,
// but for JSON files.
//
export async function updateJson<ContentType>(filePath: string, fallback: ContentType, mutator: (current: ContentType) => ContentType, retries: number = 3): Promise<void> {
    await updateFileOptimistic(filePath, fallback, mutator, raw => JSON.parse(raw) as ContentType, value => JSON.stringify(value), retries);
}

//
// Ensures a directory is empty. Deletes directory contents if it exists. Like fs-extra's emptyDir.
//
export async function emptyDir(dirPath: string): Promise<void> {
    const exists = await pathExists(dirPath);
    if (!exists) {
        await ensureDir(dirPath);
        return;
    }
    
    const entries = await fs.readdir(dirPath);
    await Promise.all(entries.map(async (entry) => {
        const entryPath = path.join(dirPath, entry);
        await remove(entryPath);
    }));
}

//
// Copies a file or directory. Works like fs-extra's copy.
//
export async function copy(src: string, dest: string): Promise<void> {
    const srcStats = await fs.stat(src);
    
    if (srcStats.isDirectory()) {
        // Copy directory recursively
        await ensureDir(dest);
        const entries = await fs.readdir(src);
        await Promise.all(entries.map(async (entry) => {
            const srcPath = path.join(src, entry);
            const destPath = path.join(dest, entry);
            await copy(srcPath, destPath);
        }));
    } else {
        // Copy file
        await ensureFileDir(dest);
        await fs.copyFile(src, dest);
    }
}

//
// Synchronous version: Ensures that the directory exists.
//
export function ensureDirSync(dirPath: string): void {
    try {
        fsSync.mkdirSync(dirPath, { recursive: true });
    } catch (error: any) {
        if (error.code === 'EEXIST') {
            // Verify it's actually a directory
            const stats = fsSync.statSync(dirPath);
            if (!stats.isDirectory()) {
                throw new Error(`Path exists but is not a directory: ${dirPath}`);
            }
        } else {
            throw error;
        }
    }
}

//
// Synchronous version: Removes a file or directory.
//
export function removeSync(targetPath: string): void {
    try {
        const stats = fsSync.statSync(targetPath);
        
        if (stats.isDirectory()) {
            fsSync.rmSync(targetPath, { recursive: true, force: true });
        } else {
            fsSync.unlinkSync(targetPath);
        }
    } catch (error: any) {
        // If file/directory doesn't exist, that's fine (like fs-extra behavior)
        if (error.code !== 'ENOENT') {
            throw error;
        }
    }
}

//
// Synchronous version: Copies a file or directory.
//
export function copySync(src: string, dest: string): void {
    const srcStats = fsSync.statSync(src);
    
    if (srcStats.isDirectory()) {
        // Copy directory recursively
        ensureDirSync(dest);
        const entries = fsSync.readdirSync(src);
        entries.forEach((entry) => {
            const srcPath = path.join(src, entry);
            const destPath = path.join(dest, entry);
            copySync(srcPath, destPath);
        });
    } else {
        // Copy file
        const destDir = path.dirname(dest);
        ensureDirSync(destDir);
        fsSync.copyFileSync(src, dest);
    }
}

//
// Returns the temp directory to use for this process.
// When TEST_TMP_DIR env var is set (test isolation mode), uses a subdirectory of the
// test's isolated dir so temp files are scoped per-test and cleaned up between runs.
// Otherwise returns the system temp dir.
//
export function getProcessTmpDir(): string {
    if (process.env.TEST_TMP_DIR) {
        return path.resolve(process.env.TEST_TMP_DIR, 'tmp');
    }
    return os.tmpdir();
}

