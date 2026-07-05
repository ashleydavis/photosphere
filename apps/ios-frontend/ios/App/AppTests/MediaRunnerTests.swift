import XCTest
@testable import App

//
// Unit tests for the media runners' deterministic contract: each runner's id and its routing of the
// tools it does not handle to the "not handled" result. The native tool paths (imagemagick on the
// ImageMagick runner, ffprobe/ffmpeg on the FFmpegKit runner) are gated on build-time link conditions
// and are exercised by the asset-processing smoke test on the simulator, so they are not asserted here.
//
final class MediaRunnerTests: XCTestCase {

    func testImageMagickRunnerId() {
        XCTAssertEqual(ImageMagickRunner().id, "ios-imagemagick")
    }

    func testImageMagickRunnerDoesNotHandleFfprobe() {
        let result = ImageMagickRunner().ffprobe(["-show_format"])
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.output, "ffprobe not handled by ImageMagickRunner")
    }

    func testImageMagickRunnerDoesNotHandleFfmpeg() {
        let result = ImageMagickRunner().ffmpeg(["-i", "in.mp4"])
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.output, "ffmpeg not handled by ImageMagickRunner")
    }

    func testFfmpegKitRunnerId() {
        XCTAssertEqual(FfmpegKitRunner().id, "ios-ffmpeg-kit-fork")
    }

    func testFfmpegKitRunnerDoesNotHandleImagemagick() {
        let result = FfmpegKitRunner().imagemagick(["info:"])
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.output, "imagemagick not handled by FfmpegKitRunner")
    }
}
