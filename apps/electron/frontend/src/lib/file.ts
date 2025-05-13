import fs from "fs";
import { computeHash } from "user-interface";
import { getImageResolution, IResolution, loadBlobToImage, resizeImageToBlob } from "user-interface";

//
// Loads a local file into a blob.
//
export async function loadFileToBlob(filePath: string, contentType: string): Promise<Blob> {
    const buffer = await fs.promises.readFile(filePath);
    return new Blob([buffer], { type: contentType });
}    

//
// Loads information about a local file.
//
export async function loadFileInfo(filePath: string, contentType: string): Promise<{ resolution: IResolution, hash: string, fileDate: Date }> {
    const stats = await fs.promises.stat(filePath);
    const blob = await loadFileToBlob(filePath, contentType);
    const image = await loadBlobToImage(blob);
    return {
        resolution: getImageResolution(image),
        hash: await computeHash(blob),
        fileDate: stats.birthtime,
    };
}

//
// Size of the thumbnail to generate and display during uploaded.
//
const PREVIEW_THUMBNAIL_MIN_SIZE = 120;

//
// Loads a thumbnail from a local file.
//
export async function loadFileToThumbnail(filePath: string, contentType: string): Promise<Blob> {
    const blob = await loadFileToBlob(filePath, contentType);
    const image = await loadBlobToImage(blob);
    return await resizeImageToBlob(image, PREVIEW_THUMBNAIL_MIN_SIZE, contentType);
}
