import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);
import { execLogged, readFileHead } from "node-utils";
import { convertExifCoordinates, getImageTransformation, IImageTransformation, ILocation, isLocationInRange, IUuidGenerator, log } from "utils";
import * as fs from "fs/promises";
import { DISPLAY_MIN_SIZE, DISPLAY_QUALITY, IAssetDetails, MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY } from "./media-file-database";
import { getFileInfo, Image } from "tools";
const exifParser = require("exif-parser");
import path from "path";

//
// How much of a photo is read to find its EXIF.
//
// EXIF sits in the APP1 segment near the start of a JPEG, and a segment is at most 64 KB, so 256 KB
// covers the header plus any embedded thumbnail comfortably. A photo whose EXIF does not fit falls
// back to a whole-file read, so this number decides how often that happens, not whether the metadata
// is found.
//
const EXIF_HEAD_BYTES = 256 * 1024;

//
// A map of EXIF tag names to their raw values, as read from a photo.
//
// The values are whatever the parser produced. Date tags come through as strings; other tags can be
// numbers or arrays, and are ignored when picking a date.
//
export interface IExifTags {
    [tagName: string]: string | number | number[] | undefined;
}

//
// The EXIF date tags, in the order they are preferred.
//
// DateTimeOriginal is when the shutter fired, which is what the date of a photo means to a person.
// DateTimeDigitized is when the image was digitised: the same instant on a digital camera, and the
// scan date for a scanned print. DateTime and ModifyDate are the file's last modification, which an
// edit or a re-encode moves, so they come last and can never displace a real capture date.
//
// The order used to be ignored: every field present was assigned in turn with nothing stopping at
// the first, so the last in the list won. Measured on a real photo, DateTimeOriginal of the 27th
// lost to ModifyDate of the 31st and the photo was filed four days late.
//
const EXIF_DATE_TAGS_IN_PRIORITY_ORDER = [
    "DateTimeOriginal",
    "DateTimeDigitized",
    "DateTime",
    "ModifyDate",
];

//
// Matches the EXIF date format, "YYYY:MM:DD HH:mm:ss".
//
// A "T" is accepted in place of the space, and anything trailing (a sub-second field, a timezone
// offset) is ignored, because a tag with more precision than EXIF specifies is still a date.
//
const EXIF_DATE_PATTERN = /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/;

//
// Turns one EXIF date string into an ISO timestamp, or undefined when it is not a date.
//
// EXIF carries no timezone, so the value is read as UTC, which is what this has always done. A
// photo's stored date does not shift because the reader changed.
//
export function parseExifDate(rawValue: string | number | number[] | undefined): string | undefined {
    if (typeof rawValue !== "string") {
        return undefined;
    }

    const match = EXIF_DATE_PATTERN.exec(rawValue.trim());
    if (!match) {
        return undefined;
    }

    const year = parseInt(match[1], 10);
    const month = parseInt(match[2], 10);
    const day = parseInt(match[3], 10);
    const hour = parseInt(match[4], 10);
    const minute = parseInt(match[5], 10);
    const second = parseInt(match[6], 10);

    // Cameras write an all-zero date when the clock has never been set. It matches the pattern and
    // is not a date, and left alone it files the photo in the year zero.
    if (year === 0 || month === 0 || day === 0) {
        return undefined;
    }

    if (month > 12 || day > 31 || hour > 23 || minute > 59 || second > 59) {
        return undefined;
    }

    // Date.UTC rolls a day past the end of its month into the next one, so a date that came back
    // different from what was asked for was never a real date.
    const asDate = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
    if (asDate.getUTCFullYear() !== year || asDate.getUTCMonth() !== month - 1 || asDate.getUTCDate() !== day) {
        return undefined;
    }

    return asDate.toISOString();
}

//
// Picks the date a photo was taken out of its EXIF tags, or undefined when they carry none.
//
// Undefined means the photo's metadata says nothing about when it was taken, and the caller falls
// back to the date of the file itself. Nothing is invented here.
//
export function pickExifDate(tags: IExifTags | undefined): string | undefined {
    if (!tags) {
        return undefined;
    }

    for (const tagName of EXIF_DATE_TAGS_IN_PRIORITY_ORDER) {
        const parsed = parseExifDate(tags[tagName]);
        if (parsed !== undefined) {
            return parsed;
        }
    }

    return undefined;
}

//
// Gets the details of an image.
//
export async function getImageDetails(filePath: string, tempDir: string, contentType: string, uuidGenerator: IUuidGenerator, logicalPath: string): Promise<IAssetDetails> {
    // filePath is always a valid file (already extracted if from zip)
    let imagePath = filePath;

    const metadataStartedAt = Date.now();
    const { dimensions: dimensionsFromMetadata, ...assetDetails } = await getImageMetadata(imagePath, contentType);
    const metadataMs = Date.now() - metadataStartedAt;
    const imageTransformation = await getImageTransformation(assetDetails.metadata);

    // The EXIF read above went through the JPEG's markers to find the tags, and the frame header
    // that gives the width and height is one of them, so for a photo that carries EXIF the size is
    // already in hand. Asking the image tool as well is a second read of the same file, and on a
    // phone that is a whole invocation of ImageMagick over the engine bridge: measured on a Pixel 6
    // it was 166 milliseconds a photo, about a seventh of everything an import does per photo.
    //
    // Anything the parser could not answer for, which is every format that is not JPEG, still asks
    // the tool. That is also what still rejects a file this cannot make an image of.
    const probeStartedAt = Date.now();
    let resolution = dimensionsFromMetadata;
    if (resolution === undefined) {
        const assetInfo = await getFileInfo(imagePath, contentType);
        if (!assetInfo) {
            throw new Error(`Unsupported file type: ${contentType}`);
        }
        resolution = assetInfo.dimensions;
    }
    const probeMs = Date.now() - probeStartedAt;


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

    // Produced largest first, each from the one before it rather than from the full size original.
    //
    // All three used to decode the original again, which on a phone is the whole photo decoded three
    // times to make three small images: micro and thumbnail together were 18.9% of an import. The
    // aspect ratio is preserved by every step, so the target dimensions are still computed from the
    // original's resolution and come out the same; what changes is how much image each decode has to
    // read. Downscaling in steps is also what an image tool does internally for a large reduction.
    const displayStartedAt = Date.now();
    const displayPath = await resizeImage(imagePath, tempDir, resolution, DISPLAY_MIN_SIZE, uuidGenerator, DISPLAY_QUALITY);
    const displayMs = Date.now() - displayStartedAt;

    const thumbnailStartedAt = Date.now();
    const thumbnailPath = await resizeImage(displayPath, tempDir, resolution, THUMBNAIL_MIN_SIZE, uuidGenerator, THUMBNAIL_QUALITY);
    const thumbnailMs = Date.now() - thumbnailStartedAt;

    const microStartedAt = Date.now();
    const microPath = await resizeImage(thumbnailPath, tempDir, resolution, MICRO_MIN_SIZE, uuidGenerator, MICRO_QUALITY);
    const microMs = Date.now() - microStartedAt;

    return {
        resolution,
        microPath,
        thumbnailPath,
        thumbnailContentType: "image/jpeg",
        displayPath,
        displayContentType: "image/jpeg",
        detailTimings: {
            metadataMs,
            probeMs,
            microMs,
            thumbnailMs,
            displayMs,
        },
        ...assetDetails
    };
}

//
// What reading a photo's EXIF found.
//
export interface IImageMetadata {
    // Every EXIF tag, as the parser read them.
    metadata?: any;

    // Where the photo was taken, when the EXIF says so and the position is a real one.
    coordinates?: ILocation;

    // When the photo was taken, from the first EXIF date field that carries one.
    photoDate?: string;

    // How big the image is, when the parser found the frame header that says so.
    //
    // Kept because it comes free: the parser reads the JPEG's markers to find the EXIF, and the
    // frame header that gives the width and height is among them. Asking an image tool for the same
    // two numbers afterwards is a second read of the same file, and on a phone that is a whole
    // invocation of ImageMagick over the engine bridge.
    dimensions?: IResolution;
}

//
// The width and height an EXIF parse found, when it found a usable pair.
//
// The parser reports the size from the JPEG's frame header, which it reads on its way to the EXIF.
// A file whose header it did not reach, or reached and made no sense of, gives nothing here and the
// caller falls back to asking an image tool.
//
export function dimensionsFromExif(exif: any): IResolution | undefined {
    const imageSize = exif?.imageSize;
    if (!imageSize) {
        return undefined;
    }

    const width = Number(imageSize.width);
    const height = Number(imageSize.height);
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
        return undefined;
    }

    return {
        width,
        height,
    };
}

//
// Gets the metadata from the image.
//
export async function getImageMetadata(filePath: string, contentType: string): Promise<IImageMetadata> {
    if (contentType === "image/jpeg" || contentType === "image/jpg") {
        try {
            let coordinates: ILocation | undefined = undefined;
            let photoDate: string | undefined = undefined;

            // Only the head of the file, not the whole photo.
            //
            // EXIF lives in the APP1 segment near the start of a JPEG, and reading the whole photo to
            // get at it was 689 milliseconds per photo on a Pixel 6: on mobile every byte crosses the
            // engine bridge as a base64 string built natively and decoded in the engine. A photo whose
            // EXIF does not fit in the head falls back to the whole file below, so nothing is lost
            // when this guess is wrong; it is only slower for that photo.
            let fileData = await readFileHead(filePath, EXIF_HEAD_BYTES);
            let parser = exifParser.create(fileData);
            parser.enableSimpleValues(false);
            let exif = parser.parse();

            if (!exif || !exif.tags || Object.keys(exif.tags).length === 0) {
                fileData = await fs.readFile(filePath);
                parser = exifParser.create(fileData);
                parser.enableSimpleValues(false);
                exif = parser.parse();
            }
            if (exif && exif.tags && exif.tags.GPSLatitude && exif.tags.GPSLongitude) {
                coordinates = convertExifCoordinates(exif.tags);
                if (!isLocationInRange(coordinates)) {
                    log.error(`Ignoring out of range GPS coordinates: ${JSON.stringify(coordinates)}, for asset ${filePath}.`);
                    coordinates = undefined;
                }
            }

            photoDate = pickExifDate(exif.tags);

            return {
                metadata: exif.tags,
                coordinates,
                photoDate,
                dimensions: dimensionsFromExif(exif),
            };
        }
        catch (err) {
            log.exception(`Failed to get exif data from ${filePath}`, err as Error);

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
    return await image.resize({ width, height, quality: Math.round(quality), format: 'jpeg', ext: 'jpg' }, tempDir, uuidGenerator);
}

//
// Transforms an image.
//
export async function transformImage(inputPath: string, tempDir: string, options: IImageTransformation, uuidGenerator: IUuidGenerator): Promise<string> {
    const image = new Image(inputPath);
    return await image.transform(options, tempDir, uuidGenerator);
}
