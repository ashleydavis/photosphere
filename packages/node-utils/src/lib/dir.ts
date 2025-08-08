import fs from 'fs-extra';
import path from 'path';

//
// Checks if the given directory path is a drive root (e.g., "C:\", "D:\").
//
function isDriveRoot(dirPath: string): boolean {
    const parsed = path.parse(dirPath);
    return parsed.root === dirPath;
}

//
// Ensures the parent directory of the given file path exists.
// If it doesn't exist, it will be created.
//
export async function ensureParentDirectoryExists(filePath: string): Promise<void> {
    const dirname = path.dirname(path.resolve(filePath));
    try {
        return await fs.ensureDir(dirname);
    }
    catch (error: any) {
        // Ignore EPERM errors for drive roots, but throw other errors.
        if (error.code !== 'EPERM' || !isDriveRoot(dirname)) {
            throw error;
        }
    }
}