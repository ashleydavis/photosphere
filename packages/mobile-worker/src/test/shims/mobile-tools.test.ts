import { Image, Video, getFileInfo } from "../../shims/mobile-tools";
import { IUuidGenerator } from "utils";

//
// One recorded invocation of a fake native media tool.
//
interface IFakeCall {
    // Which tool ran ("magick" | "ffmpeg" | "ffprobe").
    tool: string;

    // The argv the mobile tool built and passed across the bridge.
    argv: string[];
}

//
// A full native media result (exit code + captured output) for fakes that need to simulate failures.
//
interface IFakeResult {
    // Native exit code; 0 == success.
    exitCode: number;

    // Captured stdout.
    output: string;
}

//
// Options for installing the fake host.
//
interface IFakeHostOptions {
    // Paths that already exist (input files). Outputs created by producing ops are added automatically.
    existingFiles?: string[];

    // Custom ImageMagick stdout responder; defaults to a marker-based responder.
    imageMagickOutput?: (argv: string[]) => string;

    // Custom ImageMagick result responder (exit code + output); overrides imageMagickOutput when set.
    imageMagickResult?: (argv: string[]) => IFakeResult;

    // Custom ffmpeg result responder (exit code + output); defaults to a successful empty result.
    ffmpegResult?: (argv: string[]) => IFakeResult;

    // Custom ffprobe stdout (defaults to a canned probe document).
    ffprobeOutput?: string;

    // When false, producing ops do not register their output path as existing (to test the missing-output check).
    registerOutputs?: boolean;
}

//
// Default ImageMagick responder: returns canned text based on the operation markers in the argv.
//
function defaultMagickOutput(argv: string[]): string {
    const joined = argv.join(" ");
    if (joined.includes("%w %h")) {
        return "800 600";
    }
    if (joined.includes("%[EXIF:*]")) {
        return "exif:DateTimeOriginal=2023:12:25 14:30:00\nexif:Make=TestCam";
    }
    if (joined.includes("fx:int(mean")) {
        return "12,34,56";
    }
    if (joined.includes("histogram:info:")) {
        return "    100: (10,20,30) #0A141E srgb(10,20,30)\n    500: (40,50,60) #28323C srgb(40,50,60)";
    }

    return "";
}

//
// The canned ffprobe JSON document used unless a test overrides it.
//
const DEFAULT_PROBE = JSON.stringify({
    streams: [
        { codec_type: "video", codec_name: "h264", width: 1920, height: 1080, r_frame_rate: "30/1", pix_fmt: "yuv420p" },
        { codec_type: "audio", codec_name: "aac" },
    ],
    format: {
        duration: "12.5",
        bit_rate: "8000000",
        tags: { creation_time: "2023-01-02T03:04:05.000000Z", location: "+12.34-56.78/" },
    },
});

//
// Strips a known image-format prefix ("jpeg:/path" -> "/path") so the produced file path can be
// registered as existing for the post-op fsAccess check.
//
function stripFormatPrefix(token: string): string {
    const match = token.match(/^(jpeg|jpg|png|webp|gif|bmp|tiff):(.+)$/);
    return match ? match[2] : token;
}

//
// Installs a fake globalThis.host implementing the media + fsAccess functions and returns the
// recorded calls plus the existing-files set.
//
function installFakeHost(options: IFakeHostOptions): IFakeCall[] {
    const existing = new Set<string>(options.existingFiles || []);
    const calls: IFakeCall[] = [];
    const imageMagickOutput = options.imageMagickOutput || defaultMagickOutput;
    const ffprobeOutput = options.ffprobeOutput || DEFAULT_PROBE;
    const registerOutputs = options.registerOutputs !== false;

    function registerOutput(argv: string[], exitCode: number): void {
        if (registerOutputs && exitCode === 0) {
            const lastToken = argv[argv.length - 1];
            existing.add(stripFormatPrefix(lastToken));
        }
    }

    (globalThis as any).host = {
        fsAccess: (filePath: string): boolean => existing.has(filePath),
        imageMagick: (argvJson: string): string => {
            const argv = JSON.parse(argvJson) as string[];
            calls.push({ tool: "magick", argv });
            const result = options.imageMagickResult
                ? options.imageMagickResult(argv)
                : { exitCode: 0, output: imageMagickOutput(argv) };
            registerOutput(argv, result.exitCode);
            return JSON.stringify(result);
        },
        ffmpeg: (argvJson: string): string => {
            const argv = JSON.parse(argvJson) as string[];
            calls.push({ tool: "ffmpeg", argv });
            const result = options.ffmpegResult ? options.ffmpegResult(argv) : { exitCode: 0, output: "" };
            registerOutput(argv, result.exitCode);
            return JSON.stringify(result);
        },
        ffprobe: (argvJson: string): string => {
            const argv = JSON.parse(argvJson) as string[];
            calls.push({ tool: "ffprobe", argv });
            return JSON.stringify({ exitCode: 0, output: ffprobeOutput });
        },
    };

    return calls;
}

//
// A deterministic uuid generator for stable temp output paths in tests.
//
const fakeUuidGenerator: IUuidGenerator = {
    generate: (): string => "uuid-1",
};

describe("mobile tools Image", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("getDimensions parses the identify output", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const dimensions = await new Image("/cache/a.jpg").getDimensions();
        expect(dimensions).toEqual({ width: 800, height: 600 });
    });

    test("getInfo parses dimensions and the EXIF created date", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const info = await new Image("/cache/a.jpg").getInfo();
        expect(info.dimensions).toEqual({ width: 800, height: 600 });
        expect(info.hasAudio).toBe(false);
        expect(info.createdAt).toBeInstanceOf(Date);
        expect(info.createdAt!.getFullYear()).toBe(2023);
    });

    test("getInfo throws File not found when the input is missing", async () => {
        installFakeHost({ existingFiles: [] });
        await expect(new Image("/cache/missing.jpg").getInfo()).rejects.toThrow(/File not found/);
    });

    test("getInfo is cached: a second read does not re-run identify", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const image = new Image("/cache/a.jpg");
        await image.getInfo();
        const dimensionCallsAfterFirst = calls.filter(call => call.argv.includes("%w %h")).length;
        await image.getInfo();
        const dimensionCallsAfterSecond = calls.filter(call => call.argv.includes("%w %h")).length;
        expect(dimensionCallsAfterFirst).toBe(1);
        expect(dimensionCallsAfterSecond).toBe(1);
    });

    test("a read operation throws when ImageMagick exits non-zero", async () => {
        installFakeHost({
            existingFiles: ["/cache/a.jpg"],
            imageMagickResult: () => ({ exitCode: 1, output: "no decode delegate" }),
        });
        await expect(new Image("/cache/a.jpg").getDimensions()).rejects.toThrow(/ImageMagick failed/);
    });

    test("getPath returns the file path", () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        expect(new Image("/cache/a.jpg").getPath()).toBe("/cache/a.jpg");
    });

    test("getExifData parses exif lines into a map", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const exif = await new Image("/cache/a.jpg").getExifData();
        expect(exif.DateTimeOriginal).toBe("2023:12:25 14:30:00");
        expect(exif.Make).toBe("TestCam");
    });

    test("resize builds the resize argv, returns the output path, and checks it exists", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const outputPath = await new Image("/cache/a.jpg").resize(
            { width: 300, height: 300, quality: 90, format: "jpeg", ext: "jpg" },
            "/cache",
            fakeUuidGenerator,
        );
        expect(outputPath).toBe("/cache/temp_resize_uuid-1.jpg");
        const resizeCall = calls.find(call => call.argv.includes("-resize"));
        expect(resizeCall!.argv).toEqual([
            "/cache/a.jpg", "-resize", "300x300", "-quality", "90", "jpeg:/cache/temp_resize_uuid-1.jpg",
        ]);
    });

    test("resize rejects an out-of-range quality", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        await expect(new Image("/cache/a.jpg").resize(
            { width: 300, height: 300, quality: 200, format: "jpeg", ext: "jpg" },
            "/cache",
            fakeUuidGenerator,
        )).rejects.toThrow(/Quality must be between/);
    });

    test("resize builds a forced (non-aspect) geometry when maintainAspectRatio is false", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        await new Image("/cache/a.jpg").resize(
            { width: 300, height: 300, quality: 90, format: "jpeg", ext: "jpg", maintainAspectRatio: false },
            "/cache",
            fakeUuidGenerator,
        );
        const resizeCall = calls.find(call => call.argv.includes("-resize"));
        expect(resizeCall!.argv[2]).toBe("300x300!");
    });

    test("resize throws when the output file is not created", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"], registerOutputs: false });
        await expect(new Image("/cache/a.jpg").resize(
            { width: 300, height: 300, quality: 90, format: "jpeg", ext: "jpg" },
            "/cache",
            fakeUuidGenerator,
        )).rejects.toThrow(/output not created/);
    });

    test("saveAs without quality builds the plain convert argv", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const saved = await new Image("/cache/a.jpg").saveAs("/cache/out.png");
        expect(saved.getPath()).toBe("/cache/out.png");
        expect(calls[0].argv).toEqual(["/cache/a.jpg", "/cache/out.png"]);
    });

    test("saveAs rejects an out-of-range quality", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        await expect(new Image("/cache/a.jpg").saveAs("/cache/out.png", { quality: -1 }))
            .rejects.toThrow(/Quality must be between/);
    });

    test("saveAs builds the convert argv with quality and returns an Image for the output", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const saved = await new Image("/cache/a.jpg").saveAs("/cache/out.png", { quality: 80 });
        expect(saved.getPath()).toBe("/cache/out.png");
        expect(calls[0].argv).toEqual(["/cache/a.jpg", "-quality", "80", "/cache/out.png"]);
    });

    test("getDominantColor parses the R,G,B output", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const color = await new Image("/cache/a.jpg").getDominantColor();
        expect(color).toEqual([12, 34, 56]);
    });

    test("getDominantColorHistogram returns the most frequent colour", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const color = await new Image("/cache/a.jpg").getDominantColorHistogram(3);
        expect(color).toEqual([40, 50, 60]);
    });

    test("getDominantColors returns colours ranked by frequency", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const colors = await new Image("/cache/a.jpg").getDominantColors(2);
        expect(colors).toEqual([[40, 50, 60], [10, 20, 30]]);
    });

    test("getDominantColorHistogram falls back to the single-pixel method when the histogram pass fails", async () => {
        installFakeHost({
            existingFiles: ["/cache/a.jpg"],
            imageMagickResult: (argv) => {
                const joined = argv.join(" ");
                if (joined.includes("histogram:info:")) {
                    return { exitCode: 1, output: "kmeans not supported" };
                }

                return { exitCode: 0, output: "12,34,56" };
            },
        });
        const color = await new Image("/cache/a.jpg").getDominantColorHistogram();
        expect(color).toEqual([12, 34, 56]);
    });

    test("getDominantColors falls back to the single dominant colour when the histogram pass fails", async () => {
        installFakeHost({
            existingFiles: ["/cache/a.jpg"],
            imageMagickResult: (argv) => {
                const joined = argv.join(" ");
                if (joined.includes("histogram:info:")) {
                    return { exitCode: 1, output: "kmeans not supported" };
                }

                return { exitCode: 0, output: "12,34,56" };
            },
        });
        const colors = await new Image("/cache/a.jpg").getDominantColors();
        expect(colors).toEqual([[12, 34, 56]]);
    });

    test("transform builds the rotate/flop argv and returns the output path", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const outputPath = await new Image("/cache/a.jpg").transform(
            { rotate: 90, flipX: true },
            "/cache",
            fakeUuidGenerator,
        );
        expect(outputPath).toBe("/cache/temp_transform_output_uuid-1.jpg");
        expect(calls[0].argv).toEqual([
            "/cache/a.jpg", "-flop", "-rotate", "90", "/cache/temp_transform_output_uuid-1.jpg",
        ]);
    });

    test("transform returns the original path when no transform is requested", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const outputPath = await new Image("/cache/a.jpg").transform({}, "/cache", fakeUuidGenerator);
        expect(outputPath).toBe("/cache/a.jpg");
        expect(calls.length).toBe(0);
    });
});

describe("mobile tools Video", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("getInfo parses the ffprobe JSON", async () => {
        installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        const info = await new Video("/cache/v.mp4").getInfo();
        expect(info.dimensions).toEqual({ width: 1920, height: 1080 });
        expect(info.duration).toBe(12.5);
        expect(info.fps).toBe(30);
        expect(info.bitrate).toBe(8000000);
        expect(info.hasAudio).toBe(true);
        expect(info.metadata!.videoCodec).toBe("h264");
        expect(info.metadata!.audioCodec).toBe("aac");
        expect(info.metadata!.pixelFormat).toBe("yuv420p");
    });

    test("getDimensions returns the video resolution", async () => {
        installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        const dimensions = await new Video("/cache/v.mp4").getDimensions();
        expect(dimensions).toEqual({ width: 1920, height: 1080 });
    });

    test("getDuration returns the parsed duration", async () => {
        installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        const duration = await new Video("/cache/v.mp4").getDuration();
        expect(duration).toBe(12.5);
    });

    test("getPath returns the file path", () => {
        installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        expect(new Video("/cache/v.mp4").getPath()).toBe("/cache/v.mp4");
    });

    test("getInfo throws when there is no video stream", async () => {
        installFakeHost({
            existingFiles: ["/cache/v.mp4"],
            ffprobeOutput: JSON.stringify({ streams: [{ codec_type: "audio", codec_name: "aac" }], format: {} }),
        });
        await expect(new Video("/cache/v.mp4").getInfo()).rejects.toThrow(/No video stream/);
    });

    test("getInfo throws when ffprobe exits non-zero", async () => {
        installFakeHost({ existingFiles: [] });
        await expect(new Video("/cache/missing.mp4").getInfo()).rejects.toThrow(/File not found/);
    });

    test("extractScreenshot throws when the frame is not produced", async () => {
        installFakeHost({
            existingFiles: ["/cache/v.mp4"],
            ffmpegResult: () => ({ exitCode: 1, output: "decode error" }),
        });
        await expect(new Video("/cache/v.mp4").extractScreenshot("/cache/shot.jpg", 1))
            .rejects.toThrow(/Failed to extract screenshot/);
    });

    test("extractScreenshot builds the ffmpeg argv (no scale when no dimensions) and returns the path", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        const outputPath = await new Video("/cache/v.mp4").extractScreenshot("/cache/shot.jpg", 3);
        expect(outputPath).toBe("/cache/shot.jpg");
        expect(calls[0].argv).toEqual([
            "-i", "/cache/v.mp4", "-ss", "3", "-vframes", "1", "-q:v", "2", "-y", "/cache/shot.jpg",
        ]);
    });

    test("extractScreenshot adds a scale filter when dimensions are given", async () => {
        const calls = installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        await new Video("/cache/v.mp4").extractScreenshot("/cache/shot.jpg", 1, { width: 320, height: 180, quality: 90 });
        expect(calls[0].argv).toEqual([
            "-i", "/cache/v.mp4", "-ss", "1", "-vframes", "1", "-vf", "scale=320:180", "-q:v", "1", "-y", "/cache/shot.jpg",
        ]);
    });
});

describe("mobile tools getFileInfo dispatch", () => {

    afterEach(() => {
        (globalThis as any).host = undefined;
    });

    test("dispatches image/* to the Image tool", async () => {
        installFakeHost({ existingFiles: ["/cache/a.jpg"] });
        const info = await getFileInfo("/cache/a.jpg", "image/jpeg");
        expect(info!.dimensions).toEqual({ width: 800, height: 600 });
    });

    test("dispatches video/* to the Video tool", async () => {
        installFakeHost({ existingFiles: ["/cache/v.mp4"] });
        const info = await getFileInfo("/cache/v.mp4", "video/mp4");
        expect(info!.dimensions).toEqual({ width: 1920, height: 1080 });
    });

    test("returns undefined for unsupported content types", async () => {
        installFakeHost({ existingFiles: ["/cache/a.txt"] });
        const info = await getFileInfo("/cache/a.txt", "text/plain");
        expect(info).toBeUndefined();
    });
});
