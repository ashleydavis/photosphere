import * as fs from 'fs/promises';
import * as fsSync from 'fs';
import * as path from 'path';

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
//
export async function outputFile(filePath: string, data: string | Buffer, options?: { encoding?: BufferEncoding; mode?: number }): Promise<void> {
    await ensureFileDir(filePath);
    await fs.writeFile(filePath, data, options);
}

//
// Reads a JSON file and parses it. Like fs-extra's readJson.
//
export async function readJson<T = any>(filePath: string, options?: { encoding?: BufferEncoding; flag?: string }): Promise<T> {
    const data = await fs.readFile(filePath, options || { encoding: 'utf8' });
    return JSON.parse(data.toString());
}

//
// Writes an object to a JSON file. Like fs-extra's writeJson.
//
export async function writeJson(filePath: string, object: any, options?: { encoding?: BufferEncoding; spaces?: number | string; mode?: number }): Promise<void> {
    const jsonString = JSON.stringify(object, null, options?.spaces);
    await outputFile(filePath, jsonString, { encoding: options?.encoding || 'utf8', mode: options?.mode });
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

