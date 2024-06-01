import fs from 'fs';
import path from 'path';

//
// Callback for when a file is discovered.
//
export type FileFoundFn = (filePath: string) => Promise<void>;

//
// Search a directory for assets to upload.
//
export async function findAssets(directory: string, fileFound: FileFoundFn): Promise<void> {

    try {
        const files = await fs.promises.readdir(directory, { withFileTypes: true });

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
                // Check if the file is a supported asset based on its extension.
                const filePath = path.join(directory, file.name);
                await fileFound(filePath);
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
                await findAssets(dirPath, fileFound);
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