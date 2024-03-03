import { exec } from 'child_process';
import fs from 'fs';
import path from 'path';

//
// Scans the file system for images.
//
export async function scanImages() {
    const fileSystems = await getFileSystems();
    for (const fileSystem of fileSystems) {
        await findImageFiles(fileSystem);
    }
}

//
// Get a list of file systems.
//
async function getFileSystems(): Promise<string[]> {
    return new Promise<string[]>((resolve, reject) => {
        if (process.platform === 'win32') {
            // For Windows
            exec('wmic logicaldisk get name', (error: any, stdout: string) => {
                if (error) {
                    reject(error);
                    return;
                }
                const drives = stdout.split('\n')
                    .slice(1)
                    .map(drive => `${drive.trim()}/`)
                    .filter(drive => drive)
                resolve(drives);
            });
        }
        else {
            resolve(["/"]);
        }
    });
}

//
// List of image file extensions to find.
//
const imageExtensions = new Set(['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp']);

//
// Search a directory for image files.
//
async function findImageFiles(directory: string): Promise<void> {

    try {
        const files = await fs.promises.readdir(directory, { withFileTypes: true });

        for (const file of files) {
            const filePath = path.join(directory, file.name);
            if (file.isDirectory()) {
                // If the file is a directory, recursively search it.
                await findImageFiles(filePath);
            }
            else {
                // Check if the file is an image based on its extension.
                if (imageExtensions.has(path.extname(file.name).toLowerCase())) {
                    console.log(`Image file found: ${filePath}`);
                }
            }
        }
    }
    catch (error: any) {
        if (error.code === "EPERM") {
            // No access.
            return;
        }

        throw error;
    }
}