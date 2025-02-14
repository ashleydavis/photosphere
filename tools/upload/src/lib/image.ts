import dayjs from "dayjs";
import { getImageResolution, transformImage, resizeImage } from "node-utils";
import { convertExifCoordinates, getImageTransformation, ILocation, isLocationInRange } from "utils";
import { IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY, DISPLAY_MIN_SIZE, DISPLAY_QUALITY } from "./asset";
import fs from "fs-extra";
const exifParser = require("exif-parser");

//
// Gets the details of an image.
//
export async function getImageDetails(filePath: string, fileData: Buffer, contentType: string): Promise<IAssetDetails> {

    const assetDetails = await getImageMetadata(filePath, fileData, contentType);
    const imageTransformation = await getImageTransformation(assetDetails.metadata);
    let resolution = await getImageResolution(fileData);
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

    if (assetDetails.photoDate === undefined) {
        //
        // See if we can get photo date from the JSON file.
        //
        const jsonFilePath = filePath + ".json";
        if (await fs.pathExists(jsonFilePath)) {
            const jsonFileData = await fs.readFile(jsonFilePath);
            const photoData = JSON.parse(jsonFileData.toString());
            if (photoData.photoTakenTime?.timestamp) {
                try {
                    assetDetails.photoDate = dayjs.unix(parseInt(photoData.photoTakenTime.timestamp)).toISOString();
                    console.log(`Parsed date ${assetDetails.photoDate} from timestamp ${parseInt(photoData.photoTakenTime.timestamp)} in JSON file ${jsonFilePath}`);
                }
                catch (err) {
                    console.error(`Failed to parse date ${photoData.photoTakenTime.timestamp} from JSON file ${jsonFilePath}`);
                    console.error(err);
                }    
            }
        }
    }

    return { 
        resolution, 
        micro,
        thumbnail, 
        display,
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
