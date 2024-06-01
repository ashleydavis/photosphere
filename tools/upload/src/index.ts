import * as config from "./config";
import { findAssets } from "./scan";
import { IAsset, IDatabaseOp, uuid } from "database";
import axios from "axios";
import fs from "fs";
import path from "path";
import sharp from "sharp";
import dayjs from "dayjs";
import { convertExifCoordinates, isLocationInRange, retry, reverseGeocode } from "user-interface";
const exifParser = require("exif-parser");

//
// Size of the thumbnail.
//
const THUMBNAIL_MIN_SIZE = 300;

//
// Size of the display asset.
//
const DISPLAY_MIN_SIZE = 1000;

//
// Counts the number of uploads.
//
let numUploads = 0;

//
// Counts the number of assets already uploaded.
//
let numAlreadyUploaded = 0; 

//
// Counts the number of failures.
//
let numFailed = 0;

//
// Processes and uploads a single asset.
//
async function uploadAsset(filePath: string, contentType: string): Promise<void> {
    //
    // Load file data.
    // 
    const fileData = await fs.promises.readFile(filePath);

    //
    // Computes the hash and checks if we already uploaded this file.
    //
    const hash = await computeHash(fileData);    
    if (await checkUploaded(config.uploadCollectionId, hash)) {
        console.log(`Already uploaded asset ${filePath} with hash ${hash}`);
        numAlreadyUploaded += 1;
        return;
    }    
    
    const assetId = uuid();

    // console.log(`Uploading asset ${filePath} with id ${assetId} and hash ${hash}`);

    //
    // Get image resolution.
    //
    const fullImage = sharp(fileData);
    const { width, height } = await fullImage.metadata();
    if (width === undefined || height === undefined) {
        throw new Error(`Failed to get image resolution for ${filePath}`);
    }

    //
    // Uploads the full asset.
    //
    await uploadAssetData(config.uploadCollectionId, assetId, "asset", contentType, fileData);

    //
    // Uploads the thumbnail.
    //
    const thumbnailData = await resizeImage(fileData, { width, height }, THUMBNAIL_MIN_SIZE);
    await uploadAssetData(config.uploadCollectionId, assetId, "thumb", "image/jpg", thumbnailData);

    //
    // Uploads the display asset separately for simplicity and no restriction on size.
    //
    const displayData = await resizeImage(fileData, { width, height }, DISPLAY_MIN_SIZE);
    await uploadAssetData(config.uploadCollectionId, assetId, "display", "image/jpg", displayData);

    const properties: any = {};
    let location: string | undefined = undefined;
    let photoDate: string | undefined = undefined;

    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        const parser = exifParser.create(fileData.buffer);
        parser.enableSimpleValues(false);
        const exif = parser.parse();
        properties.exif = exif.tags;
        if (exif && exif.tags && exif.tags.GPSLatitude && exif.tags.GPSLongitude) {
            const coordinates = convertExifCoordinates(exif.tags);
            if (isLocationInRange(coordinates)) {
                location = await retry(() => reverseGeocode(coordinates), 3, 1500);
            }
            else {
                console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(location)}, for asset ${filePath}.`);
            }
        }

        const dateFields = ["DateTime", "DateTimeOriginal", "DateTimeDigitized"];
        for (const dateField of dateFields) {
            const dateStr = exif.tags[dateField];
            if (dateStr) {
                try {
                    photoDate = dayjs(dateStr, "YYYY:MM:DD HH:mm:ss").toISOString();
                }
                catch (err) {
                    console.error(`Failed to parse date from ${dateStr}`);
                    console.error(err);
                }
            }
        }
    }

    //
    // Read the date of the file.
    //
    const stats = await fs.promises.stat(filePath);
    const fileDate = dayjs(stats.birthtime).toISOString();
    const fileDir = path.dirname(filePath);
    const labels = fileDir.replace(/\\/g, "/")
        .split("/")
        .filter(label => label)
        .filter(label => {
            const labelLwr = label.toLowerCase();
            if (labelLwr === "z:" || labelLwr === "photos" || labelLwr === "photo library") {
                return false;
            }

            return true;
        });

    //
    // Add asset to the gallery.
    //
    await addAsset(config.uploadCollectionId, {
        _id: assetId,
        width,
        height,
        origFileName: path.basename(filePath),
        origPath: fileDir,
        hash,
        location,
        fileDate,
        photoDate,
        sortDate: photoDate || fileDate,
        uploadDate: dayjs().toISOString(),
        properties,
        labels,
        description: "",
    });   

    numUploads += 1;

    console.log(`Uploaded asset ${filePath} with id ${assetId} and hash ${hash}`);
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
};

//
// Gets the content type for a file based on its extension.
//
export function getContentType(filePath: string): string | undefined {
    const ext = path.extname(filePath).toLowerCase();
    return extMap[ext];
}

async function main(): Promise<void> {

    const failures: { filePath: string, error: any }[] = [];
    const filesNotHandled: string[] = [];

    for (const scanPath of config.paths) {        
        console.log(`Scanning path: ${scanPath}`);
        await findAssets(scanPath, async filePath => {
            // console.log(`Found asset: ${filePath}`);

            // Check if the file is a supported asset based on its extension.
            const ext = path.extname(filePath).toLowerCase();
            const contentType = extMap[ext];
            if (!contentType) {
                filesNotHandled.push(filePath);
                return;
            }

            try {
               await retry(() => uploadAsset(filePath, contentType), 3, 100);
            }
            catch (error) {
                console.error(`Failed to upload asset: ${filePath}`);
                console.error(error);
                numFailed += 1; 
                failures.push({ filePath, error });                
            }
        });
    }    

    console.log(`-- Failures --`);
    for (const failure of failures) {
        console.error(`Failed to upload asset: ${failure.filePath}`);
        console.error(failure.error);
    }

    console.log(`-- Files not handled --`);
    for (const filePath of filesNotHandled) {
        console.log(filePath);
    }

    console.log(`-- Summary --`);
    console.log(`Uploaded: ${numUploads}`);
    console.log(`Already uploaded: ${numAlreadyUploaded}`);
    console.log(`Failed: ${numFailed}`);
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
export async function computeHash(data: Buffer) {
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
    return hashHex;
}

//
// Checks if the asset is already uploaded.
//
export async function checkUploaded(collectionId: string, hash: string): Promise<boolean> {
    const url = `${config.backend}/get-one?db=${collectionId}&col=hashes&id=${hash}`;
    const response = await axios.get(
        url, 
        {
            headers: {
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
            validateStatus: status => status === 200 || status === 404,
        }
    );

    if (response.status === 404) {
        return false;
    }
    
    return response.data.assetIds.length > 0;
}

//
// Resize an image.
//
export async function resizeImage(inputData: Buffer, resolution: { width: number, height: number }, minSize: number): Promise<Buffer> {

    let width: number;
    let height: number;

    if (resolution.width > resolution.height) {
        height = minSize;
        width = Math.trunc((resolution.width / resolution.height) * minSize);
    } 
    else {
        height = Math.trunc((resolution.height / resolution.width) * minSize);
        width = minSize;
    }

    return await sharp(inputData)
        .resize(width, height, {
            fit: sharp.fit.fill,
        })
        .jpeg()
        .toBuffer();
}

//
// Uploads the data for an asset.
//
async function uploadAssetData(collectionId: string, assetId: string, assetType: string, contentType: string, data: Buffer): Promise<void> {
    await axios.post(
        `${config.backend}/asset`, 
        data, 
        {
            headers: {
                "content-type": contentType,
                col: collectionId,
                id: assetId,
                "asset-type": assetType,
                Authorization: `Bearer ${config.token}`,
                Accept: "application/json",
            },
        }
    );
}

//
// Adds an asset to the start of the gallery.
//
async function addAsset(collectionId: string, asset: IAsset): Promise<void> {
    //
    // Add the asset to the database.
    //
    const ops: IDatabaseOp[] = [
        {
            databaseName: collectionId,
            collectionName: "metadata",
            recordId: asset._id,
            op: {
                type: "set",
                fields: asset,
            },
        },
        {
            databaseName: collectionId,
            collectionName: "hashes",
            recordId: asset.hash,
            op: {
                type: "push",
                field: "assetIds",
                value: asset._id,
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

