//
// Mobile implementation of the `tools` package for the embedded worker bundle.
//
// The bundle aliases `tools` to this file (see bundle.ts). `media-file-database` and the
// node-api image/video helpers import `Image`, `Video`, and `getFileInfo` from `tools`, which on
// desktop shell out to ImageMagick/ffmpeg via `child_process`. There is no Node runtime or system
// binary in the mobile JS engine, so this implementation builds the exact same argv with the pure
// `media-commands` builders and runs them in-process through the native `host.imageMagick`/
// `host.ffmpeg`/`host.ffprobe` bridge functions, parsing the captured output the same way the
// desktop `tools` package does. The public surface matches what `node-api` consumes.
//

import path from "path";
import type { AssetInfo, Dimensions, ResizeOptions } from "tools";
import type { IUuidGenerator, IImageTransformation } from "utils";
import {
    buildIdentifyDimensionsArgs,
    buildIdentifyExifArgs,
    buildGeometry,
    buildResizeArgs,
    buildSaveArgs,
    buildDominantColorArgs,
    buildDominantColorHistogramArgs,
    buildTransformArgs,
    buildFfprobeInfoArgs,
    toFfmpegQuality,
} from "../lib/media-commands";
import { runMediaTool, getMediaHost } from "./media-access";
import { getFsHost } from "./host-access";

//
// Options accepted by Image.saveAs (format is currently advisory; the output extension picks the
// encoder, matching the desktop tool).
//
export interface ISaveAsOptions {
    // Encoder quality 0..100, when set.
    quality?: number;

    // Desired output format (advisory; the output path extension determines the encoder).
    format?: ResizeOptions["format"];
}

//
// Options accepted by Video.extractScreenshot.
//
export interface IScreenshotOptions {
    // Scaled output width in px, when set.
    width?: number;

    // Scaled output height in px, when set.
    height?: number;

    // Encoder quality 0..100, when set (defaults to 85).
    quality?: number;
}

//
// One stream entry from the ffprobe JSON output (only the fields the mobile tools read).
//
interface IFfprobeStream {
    // "video" | "audio" | other stream types.
    codec_type?: string;

    // Codec short name, e.g. "h264" / "aac".
    codec_name?: string;

    // Video stream width in px.
    width?: number;

    // Video stream height in px.
    height?: number;

    // Real frame rate as a "num/den" fraction string.
    r_frame_rate?: string;

    // Pixel format, e.g. "yuv420p".
    pix_fmt?: string;
}

//
// The container/format block from the ffprobe JSON output (only the fields the mobile tools read).
//
interface IFfprobeFormat {
    // Total duration in seconds as a string.
    duration?: string;

    // Overall bit rate in bits/sec as a string.
    bit_rate?: string;

    // Container tags (creation_time, location, etc.).
    tags?: Record<string, string>;
}

//
// The parsed ffprobe JSON document.
//
interface IFfprobeData {
    // All media streams in the file.
    streams: IFfprobeStream[];

    // The container/format metadata.
    format: IFfprobeFormat;
}

//
// Throws the desktop-compatible "File not found" error when the input path is missing.
//
function ensureFileExists(filePath: string): void {
    if (!getFsHost().fsAccess(filePath)) {
        throw new Error(`File not found: ${filePath}`);
    }
}

//
// Runs an ImageMagick argv expecting captured text on stdout (identify/info/dominant/histogram),
// throwing on a non-zero exit so read operations fail loudly like the desktop subprocess does.
//
function runImageMagickText(argv: string[]): string {
    const result = runMediaTool(getMediaHost().imageMagick, argv);
    if (result.exitCode !== 0) {
        throw new Error(`ImageMagick failed (exit code ${result.exitCode}): ${result.output}`);
    }

    return result.output;
}

//
// Runs an ImageMagick argv that produces a file, validating success with a zero exit and that the
// known output path now exists (mirroring the desktop output-file check).
//
function runImageMagickToFile(argv: string[], outputPath: string): void {
    const result = runMediaTool(getMediaHost().imageMagick, argv);
    if (result.exitCode !== 0 || !getFsHost().fsAccess(outputPath)) {
        throw new Error(`ImageMagick operation failed (exit code ${result.exitCode}), output not created: ${outputPath}`);
    }
}

//
// Parses the single-pixel dominant-colour output ("R,G,B") into an [r, g, b] triple.
//
function parseDominantColor(output: string): [number, number, number] {
    const rgbString = output.trim();
    const rgbValues = rgbString.split(",").map(value => parseInt(value.trim()));
    if (rgbValues.length === 3 && rgbValues.every(value => !isNaN(value) && value >= 0 && value <= 255)) {
        return [rgbValues[0], rgbValues[1], rgbValues[2]];
    }

    throw new Error(`Invalid RGB values: ${rgbString}`);
}

//
// One palette colour parsed from an ImageMagick histogram line, with its pixel count.
//
interface IHistogramColor {
    // The colour as an [r, g, b] triple.
    rgb: [number, number, number];

    // Number of pixels of this colour (used to rank palette entries).
    count: number;
}

//
// Parses ImageMagick `%c histogram:info:` output into ranked palette colours (most frequent first).
// Each line looks like: "   1234: (255,128,64) #FF8040 srgb(255,128,64)".
//
function parseHistogramColors(output: string): IHistogramColor[] {
    const lines = output.trim().split("\n");
    const colors: IHistogramColor[] = [];
    for (const line of lines) {
        if (line.trim()) {
            const countMatch = line.match(/^\s*(\d+):/);
            const rgbMatch = line.match(/\(([0-9.]+),([0-9.]+),([0-9.]+)\)/);
            if (countMatch && rgbMatch) {
                const count = parseInt(countMatch[1]);
                const red = Math.round(parseFloat(rgbMatch[1]));
                const green = Math.round(parseFloat(rgbMatch[2]));
                const blue = Math.round(parseFloat(rgbMatch[3]));
                colors.push({ rgb: [red, green, blue], count });
            }
        }
    }

    return colors.sort((first, second) => second.count - first.count);
}

//
// Mobile image tool. Builds ImageMagick argv and runs it through the native host bridge, parsing the
// captured output exactly like the desktop `Image`.
//
export class Image {
    //
    // The image file path this instance operates on.
    //
    private filePath: string;

    //
    // Cached asset info, populated on first read.
    //
    private _info: AssetInfo | null = null;

    constructor(filePath: string) {
        this.filePath = filePath;
    }

    //
    // Reads width/height (and EXIF created date) once, caching the result.
    //
    private getImageInfo(): AssetInfo {
        if (this._info) {
            return this._info;
        }

        ensureFileExists(this.filePath);

        const output = runImageMagickText(buildIdentifyDimensionsArgs(this.filePath));
        const parts = output.trim().split(" ");
        const width = parseInt(parts[0]);
        const height = parseInt(parts[1]);

        let createdAt: Date | undefined;
        try {
            const exifData = this.readExifData();
            if (exifData.DateTimeOriginal) {
                // Parse EXIF date format: "2023:12:25 14:30:00".
                const dateStr = exifData.DateTimeOriginal.replace(/^(\d{4}):(\d{2}):(\d{2})/, "$1-$2-$3");
                createdAt = new Date(dateStr);
            }
        }
        catch {
            // Ignore EXIF errors; dimensions are still valid.
        }

        this._info = {
            filePath: this.filePath,
            dimensions: { width, height },
            createdAt,
            duration: undefined,
            fps: undefined,
            bitrate: undefined,
            hasAudio: false,
        };

        return this._info;
    }

    //
    // Returns the image width and height.
    //
    async getDimensions(): Promise<Dimensions> {
        return this.getImageInfo().dimensions;
    }

    //
    // Returns the full asset info for the image.
    //
    async getInfo(): Promise<AssetInfo> {
        return this.getImageInfo();
    }

    //
    // Reads EXIF tags as a flat map of tag name to value (shared by getInfo and getExifData).
    //
    private readExifData(): Record<string, string> {
        const output = runImageMagickText(buildIdentifyExifArgs(this.filePath));
        const exifData: Record<string, string> = {};
        const lines = output.trim().split("\n");
        for (const line of lines) {
            const match = line.match(/exif:([^=]+)=(.*)/);
            if (match) {
                exifData[match[1]] = match[2];
            }
        }

        return exifData;
    }

    //
    // Returns the image EXIF data as a tag-to-value map.
    //
    async getExifData(): Promise<Record<string, string>> {
        ensureFileExists(this.filePath);
        return this.readExifData();
    }

    //
    // Resizes the image to a temp file and returns its path.
    //
    async resize(options: ResizeOptions, tempDir: string, uuidGenerator: IUuidGenerator): Promise<string> {
        ensureFileExists(this.filePath);

        if (options.quality < 0 || options.quality > 100) {
            throw new Error("Quality must be between 0 and 100");
        }

        const maintainAspectRatio = options.maintainAspectRatio !== false;
        let geometry: string;
        if (options.width && options.height) {
            geometry = buildGeometry(options.width, options.height, !maintainAspectRatio);
        }
        else if (options.width) {
            geometry = buildGeometry(options.width, undefined, false);
        }
        else {
            geometry = buildGeometry(undefined, options.height, false);
        }

        const outputPath = path.join(tempDir, `temp_resize_${uuidGenerator.generate()}.${options.ext}`);
        const argv = buildResizeArgs({
            inputPath: this.filePath,
            outputPath,
            geometry,
            quality: options.quality,
            format: options.format,
        });
        runImageMagickToFile(argv, outputPath);
        return outputPath;
    }

    //
    // Converts/copies the image to a new path and returns an Image for the result.
    //
    async saveAs(outputPath: string, options?: ISaveAsOptions): Promise<Image> {
        ensureFileExists(this.filePath);

        let argv: string[];
        if (options && options.quality !== undefined) {
            if (options.quality < 0 || options.quality > 100) {
                throw new Error("Quality must be between 0 and 100");
            }

            argv = buildSaveArgs({ inputPath: this.filePath, outputPath, quality: options.quality });
        }
        else {
            argv = [this.filePath, outputPath];
        }

        runImageMagickToFile(argv, outputPath);
        return new Image(outputPath);
    }

    //
    // Extracts the dominant colour by averaging to a single pixel. Returns [r, g, b].
    //
    async getDominantColor(): Promise<[number, number, number]> {
        ensureFileExists(this.filePath);
        const output = runImageMagickText(buildDominantColorArgs(this.filePath));
        return parseDominantColor(output);
    }

    //
    // Extracts the dominant colour via k-means histogram analysis, falling back to the single-pixel
    // method if the histogram pass fails. Returns [r, g, b].
    //
    async getDominantColorHistogram(colorCount?: number): Promise<[number, number, number]> {
        ensureFileExists(this.filePath);

        const count = colorCount !== undefined ? colorCount : 5;
        try {
            const output = runImageMagickText(buildDominantColorHistogramArgs({ inputPath: this.filePath, colorCount: count }));
            const colors = parseHistogramColors(output);
            if (colors.length > 0) {
                return colors[0].rgb;
            }

            return [0, 0, 0];
        }
        catch {
            return this.getDominantColor();
        }
    }

    //
    // Extracts the top palette colours via k-means histogram analysis, falling back to the single
    // dominant colour if the histogram pass fails. Returns an array of [r, g, b] triples.
    //
    async getDominantColors(colorCount?: number): Promise<Array<[number, number, number]>> {
        ensureFileExists(this.filePath);

        const count = colorCount !== undefined ? colorCount : 5;
        try {
            const output = runImageMagickText(buildDominantColorHistogramArgs({ inputPath: this.filePath, colorCount: count }));
            const colors = parseHistogramColors(output);
            return colors.map(color => color.rgb).slice(0, count);
        }
        catch {
            const dominantColor = await this.getDominantColor();
            return [dominantColor];
        }
    }

    //
    // Returns the image file path.
    //
    getPath(): string {
        return this.filePath;
    }

    //
    // Applies rotation and/or horizontal flip, writing to a temp file. Returns the original path
    // unchanged when no transform is requested.
    //
    async transform(options: IImageTransformation, tempDir: string, uuidGenerator: IUuidGenerator): Promise<string> {
        ensureFileExists(this.filePath);

        const hasFlip = options.flipX === true;
        const hasRotate = options.rotate !== undefined && options.rotate !== 0;
        if (!hasFlip && !hasRotate) {
            // No transformation needed, just return the original file.
            return this.filePath;
        }

        const outputPath = path.join(tempDir, `temp_transform_output_${uuidGenerator.generate()}.jpg`);
        const argv = buildTransformArgs({
            inputPath: this.filePath,
            outputPath,
            flip: hasFlip ? true : undefined,
            rotateDegrees: hasRotate ? options.rotate : undefined,
        });
        runImageMagickToFile(argv, outputPath);
        return outputPath;
    }
}

//
// Mobile video tool. Builds ffprobe/ffmpeg argv and runs it through the native host bridge, parsing
// the captured output exactly like the desktop `Video`.
//
export class Video {
    //
    // The video file path this instance operates on.
    //
    private filePath: string;

    //
    // Cached asset info, populated on first read.
    //
    private _info: AssetInfo | null = null;

    constructor(filePath: string) {
        this.filePath = filePath;
    }

    //
    // Runs ffprobe once and parses the JSON into asset info, caching the result.
    //
    private getVideoInfo(): AssetInfo {
        if (this._info) {
            return this._info;
        }

        ensureFileExists(this.filePath);

        const result = runMediaTool(getMediaHost().ffprobe, buildFfprobeInfoArgs(this.filePath));
        if (result.exitCode !== 0) {
            throw new Error(`Failed to get video info: ffprobe exit code ${result.exitCode}: ${result.output}`);
        }

        const probeData = JSON.parse(result.output) as IFfprobeData;
        const format = probeData.format;
        const videoStream = probeData.streams.find(stream => stream.codec_type === "video");
        const audioStream = probeData.streams.find(stream => stream.codec_type === "audio");
        if (!videoStream) {
            throw new Error("No video stream found in file");
        }

        let createdAt: Date | undefined;
        if (format.tags?.creation_time) {
            createdAt = new Date(format.tags.creation_time);
        }

        let fps: number | undefined;
        if (videoStream.r_frame_rate) {
            const [numerator, denominator] = videoStream.r_frame_rate.split("/").map(Number);
            fps = numerator / denominator;
        }

        const metadata: Record<string, string | undefined> = {
            ...(format.tags || {}),
            videoCodec: videoStream.codec_name,
            audioCodec: audioStream?.codec_name,
            pixelFormat: videoStream.pix_fmt,
        };

        this._info = {
            filePath: this.filePath,
            dimensions: {
                width: videoStream.width!,
                height: videoStream.height!,
            },
            duration: format.duration !== undefined ? parseFloat(format.duration) : undefined,
            fps,
            bitrate: format.bit_rate !== undefined ? parseInt(format.bit_rate) : undefined,
            hasAudio: !!audioStream,
            createdAt,
            metadata,
        };

        return this._info;
    }

    //
    // Returns the full asset info for the video.
    //
    async getInfo(): Promise<AssetInfo> {
        return this.getVideoInfo();
    }

    //
    // Returns the video width and height.
    //
    async getDimensions(): Promise<Dimensions> {
        return this.getVideoInfo().dimensions;
    }

    //
    // Returns the video duration in seconds (0 when unknown).
    //
    async getDuration(): Promise<number> {
        return this.getVideoInfo().duration || 0;
    }

    //
    // Extracts a single JPEG frame at a timestamp, optionally scaled, and returns the output path.
    //
    async extractScreenshot(outputPath: string, timeInSeconds?: number, options?: IScreenshotOptions): Promise<string> {
        ensureFileExists(this.filePath);

        const time = timeInSeconds !== undefined ? timeInSeconds : 1;
        const width = options?.width;
        const height = options?.height;
        const quality = options?.quality !== undefined ? options.quality : 85;

        const argv: string[] = ["-i", this.filePath, "-ss", String(time), "-vframes", "1"];
        if (width || height) {
            const scale = width && height ? `${width}:${height}`
                : width ? `${width}:-1`
                    : `-1:${height}`;
            argv.push("-vf", `scale=${scale}`);
        }

        argv.push("-q:v", String(toFfmpegQuality(quality)));
        argv.push("-y", outputPath);

        const result = runMediaTool(getMediaHost().ffmpeg, argv);
        if (result.exitCode !== 0 || !getFsHost().fsAccess(outputPath)) {
            throw new Error(`Failed to extract screenshot (exit code ${result.exitCode}): ${outputPath}`);
        }

        return outputPath;
    }

    //
    // Returns the video file path.
    //
    getPath(): string {
        return this.filePath;
    }
}

//
// Gets file information for an image or video based on content type (mirrors tools/file-info.ts).
//
export async function getFileInfo(filePath: string, contentType: string): Promise<AssetInfo | undefined> {
    if (contentType.startsWith("image/")) {
        try {
            const image = new Image(filePath);
            return await image.getInfo();
        }
        catch (error) {
            throw new Error(`Failed to get image info for ${filePath}: ${error}`);
        }
    }
    else if (contentType.startsWith("video/")) {
        try {
            const video = new Video(filePath);
            return await video.getInfo();
        }
        catch (error) {
            throw new Error(`Failed to get video info for ${filePath}: ${error}`);
        }
    }

    return undefined;
}
