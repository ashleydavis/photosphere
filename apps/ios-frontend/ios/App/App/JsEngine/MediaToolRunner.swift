import Foundation

//
// The decoded result of running one media tool invocation, mirroring the JS IMediaResult / the
// desktop tool output: an exit code and the captured stdout. The host bridge serialises this to the
// JSON string `{ exitCode, output }` the mobile `runMediaTool` helper decodes.
//
struct ToolResult {

    //
    // Native/process exit code; 0 == success.
    //
    let exitCode: Int

    //
    // Captured stdout / metadata / logs (e.g. ffprobe JSON, identify text).
    //
    let output: String
}

//
// The native runner contract. A concrete runner wraps one tool library (FFmpegKit, the ImageMagick
// shim) and runs argv in-process. The host bridge routes host.imageMagick to the ImageMagick runner
// and host.ffmpeg / host.ffprobe to the FFmpegKit runner.
//
protocol MediaToolRunner {

    //
    // Short identifier for the active runner (e.g. "ios-imagemagick", "ios-ffmpeg-kit-fork").
    //
    var id: String { get }

    //
    // Runs an ffprobe argv (no leading "ffprobe"); metadata is returned in output.
    //
    func ffprobe(_ args: [String]) -> ToolResult

    //
    // Runs an ffmpeg argv (no leading "ffmpeg"); the produced file is written directly.
    //
    func ffmpeg(_ args: [String]) -> ToolResult

    //
    // Runs a magick argv (the runner prepends "magick"); covers all ImageMagick operations.
    //
    func imagemagick(_ args: [String]) -> ToolResult
}
