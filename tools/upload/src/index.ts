import * as config from "./config";
import { findAssets } from "./scan";
import axios from "axios";
import fs from "fs-extra";
import os from "os";
import path from "path";
import dayjs from "dayjs";
import { IAsset, IDatabaseOp } from "defs";
import _ from "lodash";
import JSZip from "jszip";
import { ILocation, retry, reverseGeocode, uuid } from "utils";
import { CloudStorage, IStorage, streamAssetWithRetry, uploadFileStreamWithRetry, writeAssetWithRetry } from "storage";
const { execSync } = require('child_process');
const ColorThief = require("colorthief");

import customParseFormat from "dayjs/plugin/customParseFormat";
import { IAssetDetails } from "./lib/asset";
import { getImageDetails } from "./lib/image";
import { getVideoDetails, getVideoMetadata } from "./lib/video";
const { serializeError } = require("serialize-error");
dayjs.extend(customParseFormat);

import crypto from "node:crypto";
import { summarizeFailures } from "./lib/failures";

if (!process.env.GOOGLE_API_KEY) {
    throw new Error("GOOGLE_API_KEY environment variable not set.");
}

//
// Counts the number of uploads.
//
let numUploads = 0;

//
// Counts the number of assets already uploaded.
//
let numAlreadyUploaded = 0; 

//
// Number of uploads where the asset matches. 
//
let numUploadedWithNonMatchingHash = 0;

//
// Number of duplicate assets found against one hash.
//
let numDuplicateAssets = 0;

//
// Number of assets that were correct with Image Magick before upload.
//
let numAssetsCorrected = 0;

//
// Counts the number of failures.
//
let numFailed = 0;

//
// File extensions for files to ignore.
//
const ignoreExts = [
    ".ini",
    ".db",
	".lnk",
	".dat",
	".log",
	".htm",
	".html",
	".pdf",
	".rtf",
	".odt",
	".eml",
	".bin",
	".pln",
	".exe",
	".air",
	".url",
	".contact",
	".download",
	".js",
	".css",
	".php",
	".ico",
	".ithmb",
	".authenticate",
	".log1",
	".log2",
	".blf",
	".regtrans-ms",
	".ZFSendToTarget",
	".xml",
	".DeskLink",
	".MAPIMail",
	".csv",
	".txt",
	".cfg",
	".applesyncinfo",
	".jsx",
	".ashx",
	".searchconnector-ms",
	".3gp",
	".bs",	
    ".json",
    ".bak",
];

//
// Number of files ignored due to extension.
//
let numIgnored = 0;

//
// Processes and uploads a single asset.
//
async function uploadAsset(storage: IStorage, filePath: string, actualFilePath: string | undefined, contentType: string, fileData: Buffer | undefined, labels: string[], fileDate: string): Promise<void> {

    //
    // Load cached hash
    //
    const hashCacheDir = path.join(os.tmpdir(), "ps-upload", config.clientId, "hashes");
    const hashFilePath = path.join(hashCacheDir, `${filePath.slice(3)}.hash`);
    let hash: string;

    if (await fs.exists(hashFilePath)) {
        //
        // If the local hash file already exists, it means the asset is already uploaded.
        //
        numAlreadyUploaded += 1;
        return;
    }
    else {
        //
        // Computes the hash and checks if we already uploaded this file.
        //
        if (fileData) {
            //
            // File data is already loaded.
            //
            hash = await computeHash(fileData);    
        }
        else {
            //
            // Stream the data.
            //
            hash = await computeStreamingHash(filePath);
        }
    }

    const existingAssetIds = await checkUploaded(config.uploadSetId, hash);
    if (existingAssetIds.length === 1) {
        // const existingAssetId = existingAssetIds[0];

        //console.log(`Already uploaded asset ${filePath} with hash ${hash}`);
        numAlreadyUploaded += 1;

        //
        // Cache the hash.
        //
        await fs.ensureDir(path.dirname(hashFilePath));
        await fs.writeFile(hashFilePath, hash);

        //
        // Checks the existing file matches the hash of the local file.
        //
        // const existingData = await downloadAssetData(config.uploadSetId, existingAssetId, "asset");
        // const existingHash = await computeHash(existingData);
        // if (hash !== existingHash) {
        //     console.error(`BAD: Uploaded asset ${filePath} (${existingAssetId}) with hash ${hash} does not match existing hash ${existingHash}`);
        //     numUploadedWithNonMatchingHash += 1;
        // }
        // else {
        //     // console.log(`OK: Uploaded asset ${filePath} (${existingAssetId}) with hash ${hash} matches existing hash`);
        // }

        // //
        // // Attempt to fix existing asset date:
        // //

        // const assetData = await getAssetMetadata(existingAssetId);
        // if (assetData.photoDate === undefined) {
        //     // console.log(`No photo date for asset ${existingAssetId} with hash ${hash}`);

        //     if (assetData.properties?.metadata?.ModifyDate) {
        //         try {
        //             const photoDate = dayjs(assetData.properties.metadata.ModifyDate, "YYYY:MM:DD HH:mm:ss").toISOString();

        //             await updateAsset(existingAssetId, { photoDate });

        //             console.log(`Updated asset ${existingAssetId} with photo date ${photoDate}`);

        //             return;
        //         }
        //         catch (err) {
        //             console.error(`Failed to parse date from exif ModifyDate: ${assetData.properties.metadata.ModifyDate}`);
        //             console.error(err);
        //         }
        //     }

        //     //
        //     // See if we can get photo date from the JSON file.
        //     //
        //     const jsonFilePath = filePath + ".json";
        //     if (await fs.pathExists(jsonFilePath)) {
        //         const jsonFileData = await fs.readFile(jsonFilePath);
        //         const photoData = JSON.parse(jsonFileData.toString());
        //         if (photoData.photoTakenTime?.timestamp) {
        //             try {
        //                 const photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
        //                 console.log(`Parsed date ${assetData.photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);

        //                 await updateAsset(existingAssetId, { photoDate });

        //                 console.log(`Updated asset ${existingAssetId} with photo date ${photoDate}`);

        //                 return;
        //             }
        //             catch (err) {
        //                 console.error(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`);
        //                 console.error(err);
        //             }    
        //         }
        //     }            
        // }

        return;
    }
    else if (existingAssetIds.length > 1) {
        // console.warn(`Multiple assets with hash ${hash} found:`);
        // console.warn(existingAssetIds);

        numDuplicateAssets += 1;

        //
        // Cache the hash.
        //
        await fs.ensureDir(path.dirname(hashFilePath));
        await fs.writeFile(hashFilePath, hash);

        return;
    }
    
    const assetId = uuid();

    console.log(`Uploading asset ${filePath} with id ${assetId} and hash ${hash}`);

    let assetDetails: IAssetDetails;

    let description = "";

    //
    // Get asset resolution.
    //
    if (contentType.startsWith("video")) {
        assetDetails = await getVideoDetails(actualFilePath, fileData);
    }
    else {
        try {
            //
            // Just assume we can always load the file data into memory.
            // Some videos will be too big for this.
            //
            fileData = await fs.readFile(filePath);

            assetDetails = await getImageDetails(filePath, fileData, contentType);
        }
        catch (err) {
            console.log(`Failed to get image details for ${filePath}:`);
            console.log(err);

            const backupFilePath = `${filePath}.bak`;
            if (await fs.pathExists(backupFilePath)) {
                console.log(`Backup file already exists ${backupFilePath}, won't try to fix it again.`);

                throw err;
            }
            else {
                console.log(`Will retry after fixing the image.`);

                //
                // If it crashed, fix the image and try again.
                //
                execSync(`cp "${filePath}" "${backupFilePath}"`);
                execSync(`magick "${filePath}" "${filePath}"`); //TODO: For general uses we should be making no change to their image collections. The correct file should go in a temporary directory.

                numAssetsCorrected += 1;
                
                assetDetails = await getImageDetails(filePath, fileData!, contentType);

                labels.push("potentially corrupted");
                description = "We attempted to correct this potentially corrupted file and added the label 'potenially corrupted'";

                console.error(`This file potentially corrupted: ${filePath}`);
                console.error("We attempted to correct this potentially corrupted file and added the label 'potenially corrupted'");
            }
        }
    }

    //
    // Uploads the full asset.
    //
    await uploadAssetData(storage, config.uploadSetId, assetId, "asset", contentType, filePath, fileData);

    //
    // Uploads the thumbnail.
    //
    await uploadAssetData(storage, config.uploadSetId, assetId, "thumb", "image/jpg", undefined, assetDetails.thumbnail);

    if (assetDetails.display) {
        //
        // Uploads the display asset separately for simplicity and no restriction on size.
        //
        await uploadAssetData(storage, config.uploadSetId, assetId, "display", "image/jpg", undefined, assetDetails.display);
    }

    const properties: any = {};

    if (assetDetails.metadata) {
        properties.metadata = assetDetails.metadata;
    }

    let coordinates: ILocation | undefined = undefined;
    let location: string | undefined = undefined;
    if (assetDetails.coordinates) {
        coordinates = assetDetails.coordinates;
        const reverseGeocodingResult = await retry(() => reverseGeocode(assetDetails.coordinates!), 3, 1500);
        if (reverseGeocodingResult) {
            location = reverseGeocodingResult.location;
            properties.reverseGeocoding = {
                type: reverseGeocodingResult.type,
                fullResult: reverseGeocodingResult.fullResult,
            };
        }
    }

    //
    // Read the date of the file.
    //
    const fileDir = path.dirname(filePath);
    labels = labels.concat(fileDir.replace(/\\/g, "/")
        .split("/")
        .filter(label => label)
        .filter(label => {
            const labelLwr = label.toLowerCase();
            if (labelLwr === "z:" || labelLwr === "photos" || labelLwr === "photo library") {
                return false;
            }

            return true;
        }));

    if (config.labels) {
        labels = labels.concat(config.labels);
    }

    //
    // Add asset to the gallery.
    //
    await addAsset({
        _id: assetId,
        setId: config.uploadSetId,
        width: assetDetails.resolution.width,
        height: assetDetails.resolution.height,
        origFileName: path.basename(filePath),
        origPath: fileDir,
        contentType,
        hash,
        coordinates,
        location,
        duration: assetDetails.duration,
        fileDate,
        photoDate: assetDetails.photoDate,
        uploadDate: dayjs().toISOString(),
        properties,
        labels,
        description,
        userId: config.userId,
        micro: assetDetails.micro.toString("base64"),
        color: await ColorThief.getColor(assetDetails.thumbnail),
    });   

    numUploads += 1;

    //
    // Cache the hash if the file is uploaded.
    //
    await fs.ensureDir(path.dirname(hashFilePath));
    await fs.writeFile(hashFilePath, hash);

    console.log(`Uploaded asset ${filePath} (${contentType}) with id ${assetId} and hash ${hash}`);
}

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
    '.mpg': "video/mpeg",
    '.mpeg': "video/mpeg",
    '.mp4': "video/mp4",
    '.mov': "video/quicktime",
    '.avi': "video/x-msvideo",
    ".mkv": "video/x-matroska",
    ".wmv": "video/x-ms-wmv",
    ".webm": "video/webm",
    ".ogg": "video/ogg",
    ".ogv": "video/ogg",
    ".zip": "application/zip",
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return extMap[ext];
}

//
// Validates an asset and returns the content type.
// Returns undefined if the asset is to be ignored.
//
function validateAsset(filePath: string): string | undefined {
    for (const ignoreExt of ignoreExts) {
        if (filePath.toLowerCase().endsWith(ignoreExt.toLowerCase())) {
            numIgnored += 1;
            //console.log(`Ignored ${filePath} due to ext ${ignoreExt}`);
            return undefined;
        }
    }
    
    const ext = path.extname(filePath).toLowerCase();		

    // Check if the file is a supported asset based on its extension.
    const contentType = extMap[ext];
    if (!contentType) {
        return undefined;
    }

    return contentType;
}

//
// Unpacks a zip file.
//
async function handleZipFile(storage: IStorage, filePath: string): Promise<void> {
    // console.log(`Processing zip file: ${filePath}`);

    const stats = await fs.stat(filePath);
    const fileDate = dayjs(stats.birthtime).toISOString();

    const zip = new JSZip();
    const unpacked = await zip.loadAsync(await fs.readFile(filePath));
    for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
        if (!zipObject.dir) {
            const fullPath = `${filePath}/${fileName}`;
            // console.log(fullPath);

            const contentType = validateAsset(fullPath);
            if (!contentType) {
                continue;
            }

            try {
                const fileData = await zipObject.async("nodebuffer");
            
                await retry(() => uploadAsset(storage, fullPath, undefined, contentType, fileData, ["From zip file"], fileDate), 3, 100);
            }
            catch (error: any) {
                console.error(`Failed to upload asset: ${fullPath}`);
                console.error(error.stack || error.message || error);
                numFailed += 1; 

                await logFailure(numFailed, filePath, error);
            }
        }
    }
}

//
// Log a particular failure to disk.
//
async function logFailure(failureNumber: number, filePath: string, error: any): Promise<void> {
    await fs.ensureDir("./log/failures");
    await fs.writeFile(`./log/failures/${failureNumber}.json`, JSON.stringify({
        filePath,
        error: serializeError(error),
    }, null, 2));
}

//
// Handles a generic asset.
//
async function handleAsset(storage: IStorage, filePath: string): Promise<void> {
    const contentType = validateAsset(filePath);
    if (!contentType) {
        return;
    }

    try {
        if (contentType === "application/zip") {
            await handleZipFile(storage, filePath);
            return;
        }

        const stats = await fs.stat(filePath);
        const fileDate = dayjs(stats.birthtime).toISOString();

        await retry(() => uploadAsset(storage, filePath, filePath, contentType, undefined, [], fileDate), 3, 100);
    }
    catch (error: any) {
        console.error(`Failed to upload asset: ${filePath}`);
        console.error(error.stack || error.message || error);
        numFailed += 1; 

        await logFailure(numFailed, filePath, error);
    }
}	

async function main(): Promise<void> {

    let files: string[];

    const cachedFilesList = path.join(os.tmpdir(), "ps-upload", "files", config.clientId, "files.json");
    if (await fs.pathExists(cachedFilesList)) {
        console.log(`Loading cached files list from ${cachedFilesList}`);
        files = JSON.parse(await fs.readFile(cachedFilesList, "utf8"));
    }
    else {
        console.log(`Scanning for assets...`);

        files = [];
    
        for (const scanPath of config.paths) {        
            console.log(`Scanning path: ${scanPath}`);
            await findAssets(scanPath, config.ignoreDirs, async filePath => { 
                files.push(filePath) 
            });
        }    

        await fs.ensureDir(path.dirname(cachedFilesList));
        await fs.writeFile(cachedFilesList, JSON.stringify(files, null, 2));

        console.log(`Cached files list to ${cachedFilesList}`);
    }

    //
    // Uncomment this to focus on a specific set of files.
    //
    // files = [
    //     "full file path",
    // ];

    await fs.removeSync("./log");

    await fs.ensureDir("./log");
    await fs.writeFile("./log/files.json", JSON.stringify(files, null, 2));

    console.log(`Found ${files.length} assets.`);

    const bucket = process.env.AWS_BUCKET as string;
    if (!bucket) {
        throw new Error(`Set the AWS bucket through the environment variable AWS_BUCKET.`);
    }

    const storage = new CloudStorage(bucket);

    let numProcessed = 0;

    for (const chunk of _.chunk(files, config.batchSize)) {
        await Promise.all(chunk.map(filePath => handleAsset(storage, filePath)));

        numProcessed += chunk.length;
        if ((numProcessed % 100) === 0) {
            console.log(`Processed ${numProcessed} of ${files.length} assets.`);
        }

        if (config.maxAssets && numProcessed >= config.maxAssets) {
            console.log(`Hit max assets: ${config.maxAssets}, done.`);
            break;
        }
    }

    // console.log(`-- Failures --`);
    // for (const failure of failures) {
    //     console.error(`Failed to upload asset: ${failure.filePath}`);
    //     console.error(failure.error);
    // }

    // console.log(`-- Files not handled --`);
    // for (const filePath of filesNotHandled) {
    //     console.log(filePath);
    // }

    console.log(`-- Summary --`);
    console.log(`Total files found: ${files.length}`);
    console.log(`Processed: ${numProcessed}`);
    console.log(`Uploaded: ${numUploads}`);
    console.log(`Already uploaded: ${numAlreadyUploaded}`);
    console.log(`Uploaded not matching local hash: ${numUploadedWithNonMatchingHash}`);
    console.log(`Duplicate assets: ${numDuplicateAssets}`);
    console.log(`Assets corrected: ${numAssetsCorrected}`);
    console.log(`Failed: ${numFailed}`);
	console.log(`Ignored: ${numIgnored}`);

    await fs.writeFile("./log/summary.json", JSON.stringify({ 
        numFiles: files.length, 
        numProcessed, 
        numUploads, 
        numAlreadyUploaded, 
        numUploadedWithNonMatchingHash,
        numDuplicateAssets, 
        numAssetsCorrected,
        numFailed, 
    }, null, 2));

    await summarizeFailures("./log/failures");
}

main()
    .catch(err => {
        console.error(`Failed:`);
        console.error(err && err.stack || err);
    });

//
// Computes a hash for a file or blob of data.
// 
// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest
// https://github.com/jsdom/jsdom/issues/1612#issuecomment-663210638
// https://www.npmjs.com/package/@peculiar/webcrypto
// https://github.com/PeculiarVentures/webcrypto-docs/blob/master/README.md
//
export async function computeHash(data: Buffer): Promise<string> {
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
    return hashHex;
}

//
// Computes a hash from a file stream.
//
export async function computeStreamingHash(filePath: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
        const inputStream = fs.createReadStream(filePath);
        const hash = crypto.createHash('sha256');

        inputStream.on("data", (data: Buffer) => {
            hash.update(data);
        });

        inputStream.on("end", () => {
            const hashBuffer = hash.digest();
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
            resolve(hashHex);
        });

        inputStream.on("error", (err) => {
            reject(err);
        });
    });
}    

//
// Checks if the asset is already uploaded.
//
export async function checkUploaded(setId: string, hash: string): Promise<string[]> {
    const url = `${config.backend}/check-hash?hash=${hash}&set=${setId}`;
    const response = await axios.get(
        url, 
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );

    return response.data.assetIds;
}

//
// Uploads the data for an asset.
//
async function uploadAssetData(storage: IStorage, setId: string, assetId: string, assetType: string, contentType: string, filePath: string | undefined, data: Buffer | undefined): Promise<void> {
    // await axios.post(
    //     `${config.backend}/asset`, 
    //     data, 
    //     {
	// 		maxContentLength: Infinity,
	// 		maxBodyLength: Infinity,
    //         headers: {
    //             "content-type": contentType,
    //             set: setId,
    //             id: assetId,
    //             "asset-type": assetType,
    //             Authorization: `Bearer ${config.token}`,
    //             Accept: "application/json",
    //         },
    //     }
    // );

    //
    // Now going directly to the cloud storage to avoid problems uploading through the API.
    //
    if (data) {
        // Have the data in memory.
        await writeAssetWithRetry(storage, assetId, setId, assetType, contentType, data);
    }
    else {
        if (!filePath) {
            throw new Error("No file path or data provided.");
        }

        // Stream the data from the file.
        await uploadFileStreamWithRetry(filePath, storage, assetId, setId, assetType, contentType);
    }
}

//
// Downloads the data for an asset.
//
async function downloadAssetData(setId: string, assetId: string, assetType: string): Promise<Buffer> {
    const response = await axios.get(
        `${config.backend}/asset?set=${setId}&id=${assetId}&type=${assetType}`, 
        {
			responseType: "arraybuffer",
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "image/*,video/*",
            },
        }
    );
    return Buffer.from(response.data, 'binary');
}

//
// Adds an asset to the start of the gallery.
//
async function addAsset(asset: IAsset): Promise<void> {
    //
    // Add the asset to the database.
    //
    const ops: IDatabaseOp[] = [
        {
            collectionName: "metadata",
            recordId: asset._id,
            op: {
                type: "set",
                fields: asset,
            },
        }
    ];

    await axios.post(
        `${config.backend}/operations`, 
        {
            ops,
            clientId: config.clientId,
        },
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );    
}

//
// Gets the metadata for an asset.
//
async function getAssetMetadata(assetId: string): Promise<IAsset>  {
    const url = `${config.backend}/get-one?col=metadata&id=${assetId}`;
    const response = await axios.get(
        url, 
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );
    return response.data;
}

//
// Applies a partial update to an asset.
//
async function updateAsset(assetId: string, assetPartial: Partial<IAsset>): Promise<void> {
    //
    // Add the asset to the database.
    //
    const ops: IDatabaseOp[] = [
        {
            collectionName: "metadata",
            recordId: assetId,
            op: {
                type: "set",
                fields: assetPartial,
            },
        }
    ];

    await axios.post(
        `${config.backend}/operations`, 
        {
            ops,
            clientId: config.clientId,
        },
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );     
}
