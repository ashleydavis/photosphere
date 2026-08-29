//
// Command contract: pure functions that build argv arrays (string[]) for the
// ffmpeg / ffprobe / ImageMagick operations the mobile worker performs.
//
// These argv are the seam between the shared TypeScript and the native runners.
// On desktop the `tools` package passes equivalent argv to a forked
// `ffprobe`/`ffmpeg`/`magick` subprocess; in the embedded mobile engine the
// identical argv is passed to an in-process native entrypoint through the
// `host.imageMagick`/`host.ffmpeg`/`host.ffprobe` bridge functions. Same argv,
// same result.
//
// Tool-name convention (the first token is chosen by which native runner is
// invoked, so it is NOT included in the argv these functions return):
//   - ffprobe/ffmpeg argv: the native side runs ffprobe/ffmpeg, so argv[0] is
//     the first real flag (e.g. "-v", "-i").
//   - ImageMagick argv: the native side prepends "magick" as argv[0]. Every IM
//     operation here starts with the input path (mirroring `magick <input> ...`).
//     The dimensions/EXIF reads use the `-format ... info:` form rather than the
//     `identify` subcommand: the unified `magick` dispatcher treats argv[1] as an
//     input filename (so it can't run `identify` in-process), whereas `info:`
//     prints the formatted text to stdout, which the native shim captures.
//

//
// Options for buildFfmpegScreenshotArgs.
//
export interface IScreenshotArgs {
    // Source video path (in the writable cache dir).
    inputPath: string;

    // JPEG frame to write.
    outputPath: string;

    // Seek position in seconds.
    timeSeconds: number;

    // Scaled output width in px.
    width: number;

    // Scaled output height in px.
    height: number;

    // 0..100 (higher = better); mapped to ffmpeg -q:v.
    quality: number;
}

//
// Options for buildResizeArgs.
//
export interface IResizeArgs {
    // Source image path.
    inputPath: string;

    // Resized image to write.
    outputPath: string;

    // ImageMagick geometry, e.g. "300x300" / "300x" / "x300" / "300x300!".
    geometry: string;

    // 0..100 encoder quality.
    quality: number;

    // Output encoder: "jpeg" | "png" | "webp".
    format: string;
}

//
// Options for buildSaveArgs (format conversion without resizing).
//
export interface ISaveArgs {
    // Source image path.
    inputPath: string;

    // Output path; the extension picks the format.
    outputPath: string;

    // 0..100 encoder quality.
    quality: number;
}

//
// Options for buildDominantColorHistogramArgs.
//
export interface IHistogramArgs {
    // Source image path.
    inputPath: string;

    // Number of palette colours to extract (-kmeans N).
    colorCount: number;
}

//
// Options for buildTransformArgs.
//
export interface ITransformArgs {
    // Source image path.
    inputPath: string;

    // Transformed image to write.
    outputPath: string;

    // Clockwise rotation in degrees, when set.
    rotateDegrees?: number;

    // Horizontal mirror (-flop), when true.
    flip?: boolean;
}

//
// ffprobe: read container/stream metadata as JSON.
// `ffprobe -v quiet -print_format json -show_format -show_streams <input>`
//
export function buildFfprobeInfoArgs(inputPath: string): string[] {
    return ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", inputPath];
}

//
// Map a 0..100 quality (higher is better) to ffmpeg's -q:v scale where lower is
// better: 90 -> 1, 0 -> 10, 50 -> 5.
//
export function toFfmpegQuality(quality0to100: number): number {
    return Math.round((100 - quality0to100) / 10);
}

//
// ffmpeg: extract a single scaled JPEG frame at a timestamp (video thumbnail).
// `ffmpeg -i <input> -ss <t> -vframes 1 -vf scale=W:H -q:v <q> -y <output>`
//
export function buildFfmpegScreenshotArgs(options: IScreenshotArgs): string[] {
    return [
        "-i",
        options.inputPath,
        "-ss",
        String(options.timeSeconds),
        "-vframes",
        "1",
        "-vf",
        `scale=${options.width}:${options.height}`,
        "-q:v",
        String(toFfmpegQuality(options.quality)),
        "-y",
        options.outputPath,
    ];
}

//
// ImageMagick: read width and height.
// `magick <input> -format "%w %h" info:` -> e.g. "800 600"
//
export function buildIdentifyDimensionsArgs(inputPath: string): string[] {
    return [inputPath, "-format", "%w %h", "info:"];
}

//
// ImageMagick: dump EXIF metadata.
// `magick <input> -format "%[EXIF:*]" info:` -> "exif:Tag=value" lines
//
export function buildIdentifyExifArgs(inputPath: string): string[] {
    return [inputPath, "-format", "%[EXIF:*]", "info:"];
}

//
// Build an ImageMagick geometry string from an optional target width/height.
// When ignoreAspect is true the "!" suffix forces exact (non-aspect) sizing.
//   width+height -> "WxH", width only -> "Wx", height only -> "xH".
//
export function buildGeometry(width: number | undefined, height: number | undefined, ignoreAspect: boolean): string {
    const widthToken = width !== undefined ? String(width) : "";
    const heightToken = height !== undefined ? String(height) : "";
    const bang = ignoreAspect ? "!" : "";
    return `${widthToken}x${heightToken}${bang}`;
}

//
// ImageMagick resize: thumbnail/display sizing with quality and output format.
// `magick <input> -resize <geometry> -quality <q> -strip <format>:<output>`
//
// The original's metadata is dropped from the copy. A resize otherwise carries it in, and a photo
// from a modern phone brings an XMP block of tens of kilobytes: the forty pixel thumbnail stored
// inside every asset record was coming out at fifty kilobytes of somebody else's metadata, which
// the database then wrote into both of its sort index pages and rewrote whole on every commit.
//
// Stripped rather than picked at, because on the ImageMagick bundled for Android the surgical forms
// do not work. `+profile "!icc,icm,*"` was tried first; `+profile xmp` after it, which reads as
// though it does exactly what is wanted and silently does nothing there. Measured on a Pixel 6 with
// `+profile xmp`: a thumbnail came out at 116 KB, the database reached 194 MB at 928 photos and its
// hash index page 51 MB, and writing the database took 958 seconds of a run. With -strip, 21 MB at
// 1,850 photos, a 3.2 MB index page, and 30 seconds of writing. The cost is that a derivative loses
// its colour profile too, which is why the original is stored untouched and keeps everything.
//
export function buildResizeArgs(options: IResizeArgs): string[] {
    return [
        options.inputPath,
        "-resize",
        options.geometry,
        "-quality",
        String(options.quality),
        "-strip",
        `${options.format}:${options.outputPath}`,
    ];
}

//
// ImageMagick save/convert: change format at a quality without resizing.
// `magick <input> -quality <q> <output>` (format from the output extension).
//
export function buildSaveArgs(options: ISaveArgs): string[] {
    return [options.inputPath, "-quality", String(options.quality), options.outputPath];
}

//
// ImageMagick dominant colour via one averaged pixel.
// `magick <input> -resize 1x1! -format "<fx triple>" info:` -> "R,G,B"
//
export function buildDominantColorArgs(inputPath: string): string[] {
    return [
        inputPath,
        "-resize",
        "1x1!",
        "-format",
        "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]",
        "info:",
    ];
}

//
// ImageMagick dominant-colour palette via k-means over a histogram (top N).
// `magick <input> -resize 500x500 -kmeans <N> -format "%c" histogram:info:`
//
export function buildDominantColorHistogramArgs(options: IHistogramArgs): string[] {
    return [
        options.inputPath,
        "-resize",
        "500x500",
        "-kmeans",
        String(options.colorCount),
        "-format",
        "%c",
        "histogram:info:",
    ];
}

//
// ImageMagick transform: rotate and/or horizontally flip (orientation fix).
// `magick <input> [-flop] [-rotate <deg>] <output>` (flags only when requested).
//
export function buildTransformArgs(options: ITransformArgs): string[] {
    const args: string[] = [options.inputPath];
    if (options.flip) {
        args.push("-flop");
    }

    if (options.rotateDegrees !== undefined) {
        args.push("-rotate", String(options.rotateDegrees));
    }

    args.push(options.outputPath);
    return args;
}
