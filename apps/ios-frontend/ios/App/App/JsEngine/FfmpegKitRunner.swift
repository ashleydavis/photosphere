import Foundation

//
// iOS ffmpeg/ffprobe runner backed by the FFmpegKit SPM fork (ffmpeg-kit-full-spm). The
// com.arthenica FFmpegKit API is identical across the surviving forks, so this code is stable even if
// the chosen fork changes. imagemagick is handled by the ImageMagick runner.
//
// The body is gated on `canImport(ffmpegkit)` so the App target still compiles before the SPM package
// is added (it then reports "not linked"). Add the package in Xcode (File > Add Package Dependencies)
// to activate it; see the iOS section of README.md.
//
#if canImport(ffmpegkit)
import ffmpegkit
#endif

struct FfmpegKitRunner: MediaToolRunner {

    //
    // Identifier for this runner, surfaced in diagnostics.
    //
    let id = "ios-ffmpeg-kit-fork"

    //
    // Runs an ffprobe argv in-process and returns its exit code and captured output (the ffprobe JSON).
    //
    func ffprobe(_ args: [String]) -> ToolResult {
        #if canImport(ffmpegkit)
        let session = FFprobeKit.execute(withArguments: args)
        let exitCode = Int(session?.getReturnCode()?.getValue() ?? -1)
        let output = session?.getOutput() ?? ""
        return ToolResult(exitCode: exitCode, output: output)
        #else
        return ToolResult(exitCode: -1, output: "ffmpegkit not linked")
        #endif
    }

    //
    // Runs an ffmpeg argv in-process (e.g. the screenshot extraction) and returns its exit code.
    //
    func ffmpeg(_ args: [String]) -> ToolResult {
        #if canImport(ffmpegkit)
        let session = FFmpegKit.execute(withArguments: args)
        let exitCode = Int(session?.getReturnCode()?.getValue() ?? -1)
        let output = session?.getOutput() ?? ""
        return ToolResult(exitCode: exitCode, output: output)
        #else
        return ToolResult(exitCode: -1, output: "ffmpegkit not linked")
        #endif
    }

    //
    // Not handled here; the bridge routes imagemagick to the ImageMagick runner.
    //
    func imagemagick(_ args: [String]) -> ToolResult {
        return ToolResult(exitCode: -1, output: "imagemagick not handled by FfmpegKitRunner")
    }
}
