import dayjs from "dayjs";
import { transformImage, resizeImage } from "node-utils";
import { convertExifCoordinates, getImageTransformation, ILocation, isLocationInRange } from "utils";
import fs from "fs-extra";
import { Readable } from "stream";
import { DISPLAY_MIN_SIZE, DISPLAY_QUALITY, IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY } from "./media-file-database";
import { buffer } from "node:stream/consumers";
import { getFileInfo } from "tools";
const exifParser = require("exif-parser");

//
// Gets the details of an image.
//
export async function getImageDetails(filePath: string, contentType: string, openStream?: () => Readable): Promise<IAssetDetails> {

    let fileData = openStream ? await buffer(openStream()) : await fs.promises.readFile(filePath);
    
    // Use the new getFileInfo function to get basic info and dimensions  
    const assetInfo = await getFileInfo(filePath, contentType);
    if (!assetInfo) {
        throw new Error(`Unsupported file type: ${contentType}`);
    }
    
    // Still use the existing EXIF parsing for metadata compatibility
    const assetDetails = await getImageMetadata(filePath, fileData, contentType);
    const imageTransformation = await getImageTransformation(assetDetails.metadata);
    let resolution = assetInfo.dimensions;
    
    if (imageTransformation) {
        // Flips orientation depending on exif data.
        fileData = await transformImage(fileData, imageTransformation);
        if (imageTransformation.changeOrientation) {
            resolution = {
                width: resolution.height,
                height: resolution.width,
            };
        }
    }

    const micro = await resizeImage(fileData, resolution, MICRO_MIN_SIZE, MICRO_QUALITY);
    const thumbnail = await resizeImage(fileData, resolution, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY);
    const display = await resizeImage(fileData, resolution, DISPLAY_MIN_SIZE, DISPLAY_QUALITY);

    return { 
        resolution, 
        micro,
        thumbnail, 
        thumbnailContentType: "image/jpeg",
        display,
        displayContentType: "image/jpeg",
        ...assetDetails 
    };
}

//
// Gets the metadata from the image.
//
export async function getImageMetadata(filePath: string, fileData: Buffer, contentType: string): Promise<{ metadata?: any, coordinates?: ILocation, photoDate?: string }> {
    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        try {
            let coordinates: ILocation | undefined = undefined;
            let photoDate: string | undefined = undefined;

            const parser = exifParser.create(fileData.buffer);
            parser.enableSimpleValues(false);
            const exif = parser.parse();
            if (exif && exif.tags && exif.tags.GPSLatitude && exif.tags.GPSLongitude) {
                coordinates = convertExifCoordinates(exif.tags);
                if (!isLocationInRange(coordinates)) {
                    console.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(coordinates)}, for asset ${filePath}.`);
                    coordinates = undefined;
                }
            }

            const dateFields = ["DateTime", "DateTimeOriginal", "DateTimeDigitized", "ModifyDate"];
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

            return {
                metadata: exif.tags,
                coordinates,
                photoDate
            };
        }
        catch (err) {
            console.error(`Failed to get exif data from ${filePath}`);
            console.error(err);

            return {};
        }
    }
    else {
        return {};
    }
}
