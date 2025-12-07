//
// Utility functions for extracting files from zip files
//

import JSZip from "jszip";
import fs from "fs-extra";
import { buffer } from "node:stream/consumers";

//
// Extracts a file from a zip file and returns a readable stream.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip
//
export async function extractFileFromZip(zipFilePath: string, filePath: string): Promise<NodeJS.ReadableStream> {
    const zip = new JSZip();
    const zipData = await fs.readFile(zipFilePath);
    const unpacked = await zip.loadAsync(zipData);
    
    const zipObject = unpacked.files[filePath];
    if (!zipObject || zipObject.dir) {
        throw new Error(`File "${filePath}" not found in zip "${zipFilePath}"`);
    }
    
    return zipObject.nodeStream();
}

//
// Extracts a nested zip file from a parent zip and returns a readable stream.
// This handles the case where a zip file contains another zip file.
//
export async function extractNestedZipFromParent(parentZipFilePath: string, nestedZipRelativePath: string): Promise<NodeJS.ReadableStream> {
    const parentZip = new JSZip();
    const parentData = await fs.readFile(parentZipFilePath);
    const unpacked = await parentZip.loadAsync(parentData);
    const nestedZipObject = unpacked.files[nestedZipRelativePath];
    if (!nestedZipObject || nestedZipObject.dir) {
        throw new Error(`Nested zip file "${nestedZipRelativePath}" not found in parent zip "${parentZipFilePath}"`);
    }
    return nestedZipObject.nodeStream();
}

//
// Extracts a file from a zip (possibly nested) and returns a readable stream.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip (may include nested zip paths like "nested.zip/file.jpg")
//
export async function extractFileFromZipRecursive(zipFilePath: string, filePath: string): Promise<NodeJS.ReadableStream> {
    // Check if filePath indicates a nested zip (contains a .zip in the path)
    const pathParts = filePath.split(/[/\\]/);
    const zipIndex = pathParts.findIndex(part => part.endsWith('.zip') && part !== pathParts[pathParts.length - 1]);
    
    if (zipIndex !== -1) {
        // File is in a nested zip
        const nestedZipPath = pathParts.slice(0, zipIndex + 1).join('/');
        const fileInNestedZip = pathParts.slice(zipIndex + 1).join('/');
        
        // Extract the nested zip first
        const nestedZipStream = await extractNestedZipFromParent(zipFilePath, nestedZipPath);
        
        // Load the nested zip and extract the file
        const nestedZip = new JSZip();
        const nestedZipData = await buffer(nestedZipStream);
        const nestedUnpacked = await nestedZip.loadAsync(nestedZipData);
        const fileObject = nestedUnpacked.files[fileInNestedZip];
        if (!fileObject || fileObject.dir) {
            throw new Error(`File "${fileInNestedZip}" not found in nested zip "${nestedZipPath}" within "${zipFilePath}"`);
        }
        return fileObject.nodeStream();
    } else {
        // File is directly in the zip
        return extractFileFromZip(zipFilePath, filePath);
    }
}

