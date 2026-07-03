import {
    buildFfprobeInfoArgs,
    toFfmpegQuality,
    buildFfmpegScreenshotArgs,
    buildIdentifyDimensionsArgs,
    buildIdentifyExifArgs,
    buildGeometry,
    buildResizeArgs,
    buildSaveArgs,
    buildDominantColorArgs,
    buildDominantColorHistogramArgs,
    buildTransformArgs,
} from "../lib/media-commands";

//
// Unit tests for the pure argv builders. Each asserts the exact argv array the
// native runners receive, so any drift in the command contract fails loudly.
//
describe("media-commands argv builders", () => {

    test("buildFfprobeInfoArgs produces the exact probe argv", () => {
        expect(buildFfprobeInfoArgs("/cache/sample.mp4")).toEqual([
            "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "/cache/sample.mp4",
        ]);
    });

    test("toFfmpegQuality maps 90 -> 1", () => {
        expect(toFfmpegQuality(90)).toBe(1);
    });

    test("toFfmpegQuality maps 0 -> 10", () => {
        expect(toFfmpegQuality(0)).toBe(10);
    });

    test("toFfmpegQuality maps 50 -> 5", () => {
        expect(toFfmpegQuality(50)).toBe(5);
    });

    test("buildFfmpegScreenshotArgs produces the exact screenshot argv", () => {
        expect(buildFfmpegScreenshotArgs({
            inputPath: "/cache/sample.mp4",
            outputPath: "/cache/shot.jpg",
            timeSeconds: 1,
            width: 320,
            height: 180,
            quality: 90,
        })).toEqual([
            "-i", "/cache/sample.mp4", "-ss", "1", "-vframes", "1",
            "-vf", "scale=320:180", "-q:v", "1", "-y", "/cache/shot.jpg",
        ]);
    });

    test("buildIdentifyDimensionsArgs produces the dimensions argv (info: form)", () => {
        expect(buildIdentifyDimensionsArgs("/cache/sample.jpg")).toEqual([
            "/cache/sample.jpg", "-format", "%w %h", "info:",
        ]);
    });

    test("buildIdentifyExifArgs produces the EXIF argv (info: form)", () => {
        expect(buildIdentifyExifArgs("/cache/sample.jpg")).toEqual([
            "/cache/sample.jpg", "-format", "%[EXIF:*]", "info:",
        ]);
    });

    test("buildGeometry handles width and height", () => {
        expect(buildGeometry(300, 300, false)).toBe("300x300");
    });

    test("buildGeometry handles width only", () => {
        expect(buildGeometry(300, undefined, false)).toBe("300x");
    });

    test("buildGeometry handles height only", () => {
        expect(buildGeometry(undefined, 300, false)).toBe("x300");
    });

    test("buildGeometry adds ! when ignoreAspect is true", () => {
        expect(buildGeometry(300, 300, true)).toBe("300x300!");
    });

    test("buildResizeArgs produces the resize argv with format prefix", () => {
        expect(buildResizeArgs({
            inputPath: "/cache/sample.jpg",
            outputPath: "/cache/out.jpg",
            geometry: "300x300",
            quality: 90,
            format: "jpeg",
        })).toEqual([
            "/cache/sample.jpg", "-resize", "300x300", "-quality", "90", "jpeg:/cache/out.jpg",
        ]);
    });

    test("buildSaveArgs produces the save/convert argv", () => {
        expect(buildSaveArgs({
            inputPath: "/cache/sample.jpg",
            outputPath: "/cache/out.png",
            quality: 90,
        })).toEqual(["/cache/sample.jpg", "-quality", "90", "/cache/out.png"]);
    });

    test("buildDominantColorArgs produces the single-pixel dominant argv", () => {
        expect(buildDominantColorArgs("/cache/sample.jpg")).toEqual([
            "/cache/sample.jpg", "-resize", "1x1!",
            "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:",
        ]);
    });

    test("buildDominantColorHistogramArgs produces the kmeans histogram argv", () => {
        expect(buildDominantColorHistogramArgs({
            inputPath: "/cache/sample.jpg",
            colorCount: 5,
        })).toEqual([
            "/cache/sample.jpg", "-resize", "500x500", "-kmeans", "5", "-format", "%c", "histogram:info:",
        ]);
    });

    test("buildTransformArgs handles rotate only", () => {
        expect(buildTransformArgs({ inputPath: "/cache/a.jpg", outputPath: "/cache/b.jpg", rotateDegrees: 90 }))
            .toEqual(["/cache/a.jpg", "-rotate", "90", "/cache/b.jpg"]);
    });

    test("buildTransformArgs handles flip only", () => {
        expect(buildTransformArgs({ inputPath: "/cache/a.jpg", outputPath: "/cache/b.jpg", flip: true }))
            .toEqual(["/cache/a.jpg", "-flop", "/cache/b.jpg"]);
    });

    test("buildTransformArgs handles both flip and rotate", () => {
        expect(buildTransformArgs({ inputPath: "/cache/a.jpg", outputPath: "/cache/b.jpg", flip: true, rotateDegrees: 90 }))
            .toEqual(["/cache/a.jpg", "-flop", "-rotate", "90", "/cache/b.jpg"]);
    });

    test("buildTransformArgs handles neither flip nor rotate", () => {
        expect(buildTransformArgs({ inputPath: "/cache/a.jpg", outputPath: "/cache/b.jpg" }))
            .toEqual(["/cache/a.jpg", "/cache/b.jpg"]);
    });
});
