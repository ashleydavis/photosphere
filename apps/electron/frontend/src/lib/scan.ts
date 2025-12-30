import { exec } from 'child_process';
import * as fs from "fs/promises";
import path from 'path';
import { sleep } from 'utils';

//
// Information on a file.
//
export interface IFileDetails {
    //
    // The path of the file.
    //
    path: string;

    //
    // The content type of the file.
    //
    contentType: string;
}

//
// Callback for when a file is discovered.
//
export type FileFoundFn = (fileDetails: IFileDetails) => Promise<void>;

//
// Scans the file system for images.
//
export async function scanImages(fileFound: FileFoundFn): Promise<void> {
    const fileSystems = await getFileSystems();
    for (const fileSystem of fileSystems) {
        await findImageFiles(fileSystem, fileFound);
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
const imageExtensions: { [index: string]: string } = {
    '.jpg': "image/jpeg", 
    '.jpeg': "image/jpeg", 
    '.png': "image/png", 
    '.gif': "image/gif", 
    '.bmp': "image/bmp", 
    '.tiff': "image/tiff", 
    '.webp': "image/webp",
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return imageExtensions[ext];
}

//
// Search a directory for image files.
//
async function findImageFiles(directory: string, fileFound: FileFoundFn): Promise<void> {

    try {
        const files = await fs.readdir(directory, { withFileTypes: true });

        //
        // Sleep to give the UI time to be responsive.
        //
        await sleep(10);

        //
        // Process files in this directory.
        // Files are processed first to main stability of the gallery without having to sort the assets.
        //
        for (const file of files) {
            if (file.isDirectory()) {
                // Do directories on the next pass.
                continue;
            }
            else {
                // Check if the file is an image based on its extension.
                const ext = path.extname(file.name).toLowerCase();
                const contentType = imageExtensions[ext];
                if (contentType) {
                    const filePath = path.join(directory, file.name);
                    await fileFound({ 
                        path: filePath,
                        contentType,
                    });

                    //
                    // Sleep to give the UI time to be responsive.
                    //
                    await sleep(10);
                }
            }
        }

        //
        // Process subdirectories in this directory.
        //
        for (const file of files) {
            if (file.isDirectory()) {
                if (file.name.toLowerCase() === "$recycle.bin") {
                    continue;
                }
                
                // If the file is a directory, recursively search it.
                const dirPath = path.join(directory, file.name);
                await findImageFiles(dirPath, fileFound);
            }
            else {
                // Did files on the previous pass.
                continue;
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