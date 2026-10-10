//
// The ImageMagick runner. It calls the in-process `magick` dispatcher through the run_magick C shim (run_magick.c), backed by the iOS
// ImageMagick static libraries, so every ImageMagick operation runs from one argument list. ffprobe and ffmpeg are the FFmpegKit
// runner's.
//

import Foundation
import ZiggyShellIOS

// Runs ImageMagick in this process.
final class ImageMagickRunner {
    // Serialises every ImageMagick call. The shim redirects the process-wide stdout file descriptor around MagickCommandGenesis to
    // capture text output, so concurrent calls must not overlap. FFmpegKit captures per session and needs no such lock.
    private let lock = NSLock()

    // Runs a magick argument list in-process. Prepends "magick" (the argument list omits the tool name), redirects stdout to a capture
    // file of this call's own inside the shim, and returns the captured text with the dispatcher's exit code.
    func run(_ args: [String]) throws -> ToolResult {
        lock.lock()
        defer {
            lock.unlock()
        }

        let capturePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("magick-capture-\(UUID().uuidString).txt")

        // The magick dispatcher expects argv[0] == "magick".
        let argv = ["magick"] + args
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { argument in
            strdup(argument)
        }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(pointer)
            }
        }

        let code = run_magick(Int32(argv.count), &cargs, capturePath)
        let output: String
        do {
            output = try String(contentsOfFile: capturePath, encoding: .utf8)
            try FileManager.default.removeItem(atPath: capturePath)
        }
        catch {
            throw ZiggyHostRequestError("ImageMagick's output could not be read back: \(error)")
        }
        return ToolResult(exitCode: Int(code), output: output)
    }
}
