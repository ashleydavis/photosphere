import { exec } from 'child_process';
import fs from 'fs';
import path from 'path';

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
const imageExtensions: any = {
    '.jpg': "image/jpeg", 
    '.jpeg': "image/jpeg", 
    '.png': "image/png", 
    '.gif': "image/gif", 
    '.bmp': "image/bmp", 
    '.tiff': "image/tiff", 
    // '.webp': "image/webp",
};

//
// Search a directory for image files.
//
async function findImageFiles(directory: string, fileFound: FileFoundFn): Promise<void> {

    try {
        const files = await fs.promises.readdir(directory, { withFileTypes: true });

        for (const file of files) {
            const filePath = path.join(directory, file.name);
            if (file.isDirectory()) {
                // If the file is a directory, recursively search it.
                await findImageFiles(filePath, fileFound);
            }
            else {
                // Check if the file is an image based on its extension.
                const ext = path.extname(file.name).toLowerCase();
                const contentType = imageExtensions[ext];
                console.log(`Extension ${ext} has content type ${contentType} for file ${file.name} at path ${filePath}`); //fio:
                if (contentType) {
                    await fileFound({ 
                        path: path.join(file.path, file.name),
                        contentType,
                    });
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