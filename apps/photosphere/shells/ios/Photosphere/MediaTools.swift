//
// Answers the core's requests to run ImageMagick, ffmpeg and ffprobe, which iOS has no programs for. Each request is the JSON
// {"args": [...]} (the tool's arguments, not its name) and is answered with {"exitCode": number, "output": text}. A tool that ends
// with a non-zero code is still an answer: the core decides what that means.
//

import Foundation
import ZiggyShellIOS

// The result of running one media tool: an exit code and what the tool printed.
struct ToolResult {
    // The tool's exit code; 0 is success.
    let exitCode: Int

    // What the tool printed (ffprobe JSON, identify text, logs).
    let output: String
}

// The three media tools.
final class MediaTools {
    // Runs ImageMagick.
    private let imageMagick = ImageMagickRunner()

    // Runs ffmpeg and ffprobe.
    private let ffmpegKit = FfmpegKitRunner()

    // Runs the tool the method names (runMagick, runFfmpeg or runFfprobe) with the request's arguments.
    func run(method: String, requestJson: String) throws -> String {
        let request = try HostJson.object(from: requestJson, method: method)
        guard let args = request["args"] as? [String] else {
            throw ZiggyHostRequestError("The request \(method) was not understood: \"args\" is missing or is not a list of text.")
        }
        let result: ToolResult
        switch method {
        case "runMagick":
            result = try imageMagick.run(args)
        case "runFfmpeg":
            result = try ffmpegKit.ffmpeg(args)
        case "runFfprobe":
            result = try ffmpegKit.ffprobe(args)
        default:
            throw ZiggyHostRequestError("There is no media tool for \"\(method)\".")
        }
        let reply: [String: Any] = [
            "exitCode": result.exitCode,
            "output": result.output,
        ]
        return try HostJson.text(from: reply, method: method)
    }
}
