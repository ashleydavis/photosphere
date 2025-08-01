import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);
import { execLogged, writeStreamToFile } from "node-utils";
import { tmpdir } from "os";
import { join } from "path";
import { convertExifCoordinates, getImageTransformation, IImageTransformation, ILocation, isLocationInRange, IUuidGenerator } from "utils";
import fs from "fs-extra";
import path from "path";
import { DISPLAY_MIN_SIZE, DISPLAY_QUALITY, IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY } from "./media-file-database";
import { getFileInfo } from "tools";
import { Readable } from "stream";
const exifParser = require("exif-parser");
import { Image } from "tools";
import mime from 'mime';

//
// Gets the details of an image.
//
export async function getImageDetails(filePath: string, tempDir: string, contentType: string, uuidGenerator: IUuidGenerator, openStream?: () => NodeJS.ReadableStream): Promise<IAssetDetails> {

    let imagePath: string;

    if (openStream) {
        // Choose extension based on content type.            
        const ext = mime.getExtension(contentType);
        if (!ext) {
            throw new Error(`Unsupported content type: ${contentType}`);
        }

        // If openStream is provided, we need to extract to a temporary file.        
        imagePath = join(tmpdir(), `temp_asset_${uuidGenerator.generate()}.${ext}`);
        await writeStreamToFile(openStream(), imagePath);        
    }
    else {
        // Use the file directly from its location on disk.
        imagePath = filePath;
    }

    const assetInfo = await getFileInfo(imagePath, contentType);
    if (!assetInfo) {
        throw new Error(`Unsupported file type: ${contentType}`);
    }
    
    const assetDetails = await getImageMetadata(imagePath, contentType);
    const imageTransformation = await getImageTransformation(assetDetails.metadata);
    let resolution = assetInfo.dimensions;
    
    if (imageTransformation) {
        // Flips orientation depending on exif data.
        imagePath = await transformImage(imagePath, tempDir, imageTransformation, uuidGenerator);
        if (imageTransformation.changeOrientation) {
            resolution = {
                width: resolution.height,
                height: resolution.width,
            };
        }
    }

    const microPath = await resizeImage(imagePath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);
    const thumbnailPath = await resizeImage(imagePath, tempDir, resolution, THUMBNAIL_MIN_SIZE, uuidGenerator, THUMBNAIL_QUALITY);
    const displayPath = await resizeImage(imagePath, tempDir, resolution, DISPLAY_MIN_SIZE, uuidGenerator, DISPLAY_QUALITY);

    return { 
        resolution, 
        microPath,
        thumbnailPath, 
        thumbnailContentType: "image/jpeg",
        displayPath,
        displayContentType: "image/jpeg",
        ...assetDetails 
    };
}

//
// Gets the metadata from the image.
//
export async function getImageMetadata(filePath: string, contentType: string): Promise<{ metadata?: any, coordinates?: ILocation, photoDate?: string }> {
    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        try {
            let coordinates: ILocation | undefined = undefined;
            let photoDate: string | undefined = undefined;

            const fileData = await fs.readFile(filePath); //TODO: Move exif extraction to image magick so as not to load the entire file into memory.
            const parser = exifParser.create(fileData);
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
                        photoDate = dayjs.utc(dateStr, "YYYY:MM:DD HH:mm:ss").toISOString();
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

//
// Represents the resolution of the image or video.
//
export interface IResolution {
    //
    // The width of the image or video.
    //
    width: number;

    //
    // The height of the image or video.
    //
    height: number;
}

//
// Resize an image.
//
export async function resizeImage(inputPath: string, tempDir: string, resolution: { width: number, height: number }, minSize: number, uuidGenerator: IUuidGenerator, quality: number = 90): Promise<string> {

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

    const image = new Image(inputPath);
    const outputPath = join(tmpdir(), `temp_resize_${uuidGenerator.generate()}.jpg`);
    await image.resize({ width, height, quality: Math.round(quality), format: 'jpeg' }, outputPath);
    return outputPath;
}

//
// Transforms an image.
//
export async function transformImage(inputPath: string, tempDir: string, options: IImageTransformation, uuidGenerator: IUuidGenerator): Promise<string> {

    let transformCommand = '';

    if (options.flipX) {
        transformCommand += ' -flop';
    }

    if (options.rotate) {
        transformCommand += ` -rotate ${options.rotate}`;
    }

    if (transformCommand) {
        // Transform to a temporary file and return the path.
        const outputPath = join(tmpdir(), `temp_transform_output_${uuidGenerator.generate()}.jpg`);
        const command = `magick convert "${inputPath}" ${transformCommand} "${outputPath}"`;
        await execLogged('magick', command);

        // Check if the output file was created successfully.
        if (!await fs.pathExists(outputPath)) { 
            throw new Error(`Image transformation failed, output file not created: ${outputPath}`);
        }
        return outputPath;
    }
    else {
        // No transformations needed, just return the original file.
        return inputPath;
    }
}
