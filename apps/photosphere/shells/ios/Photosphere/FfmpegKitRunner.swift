//
// The ffmpeg and ffprobe runner, backed by the FFmpegKit package (ffmpeg-kit-full-spm). ImageMagick is the ImageMagick runner's.
//

import Foundation
import ZiggyShellIOS
import ffmpegkit

// Runs ffmpeg and ffprobe in this process.
final class FfmpegKitRunner {
    // Runs an ffprobe argument list in-process and returns its exit code and captured output (the ffprobe JSON).
    func ffprobe(_ args: [String]) throws -> ToolResult {
        guard let session = FFprobeKit.execute(withArguments: args) else {
            throw ZiggyHostRequestError("FFmpegKit gave no session for ffprobe.")
        }
        return try result(of: session, tool: "ffprobe")
    }

    // Runs an ffmpeg argument list in-process (for instance the screenshot extraction) and returns its exit code and output.
    func ffmpeg(_ args: [String]) throws -> ToolResult {
        guard let session = FFmpegKit.execute(withArguments: args) else {
            throw ZiggyHostRequestError("FFmpegKit gave no session for ffmpeg.")
        }
        return try result(of: session, tool: "ffmpeg")
    }

    // Reads the exit code and the output out of a session that has finished.
    private func result(of session: Session, tool: String) throws -> ToolResult {
        guard let returnCode = session.getReturnCode() else {
            throw ZiggyHostRequestError("FFmpegKit gave no exit code for \(tool).")
        }
        return ToolResult(exitCode: Int(returnCode.getValue()), output: session.getOutput() ?? "")
    }
}
