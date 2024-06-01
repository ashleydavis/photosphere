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
// Maps supported file extensions to content type.
//
const extMap: { [index: string]: string } = {
    '.jpg': "image/jpeg", 
    '.jpeg': "image/jpeg", 
    '.png': "image/png", 
    '.gif': "image/gif", 
    // '.bmp': "image/bmp", Not supported by sharp.
    '.tiff': "image/tiff", 
    '.webp': "image/webp",
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return extMap[ext];
}
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
                const ext = path.extname(file.name).toLowerCase();
                const contentType = extMap[ext];
                if (contentType) {
                    const filePath = path.join(directory, file.name);
                    await fileFound({ 
                        path: filePath,
                        contentType,
                    });
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