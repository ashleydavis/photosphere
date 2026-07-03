import Foundation

//
// iOS ImageMagick runner. Calls the in-process `magick` dispatcher through the run_magick C shim
// (run_magick.c) via the bridging header, backed by the iOS ImageMagick static libraries. Handles
// every ImageMagick operation via the single argv method; ffprobe/ffmpeg go to the FFmpegKit runner.
//
// The call to run_magick is gated on the `IMAGEMAGICK_LINKED` active compilation condition so the App
// target compiles before the bridging header, static libs, and header search paths are configured.
// Enable the condition (Build Settings > Swift Compiler - Custom Flags) after wiring; see the iOS
// section of README.md.
//
struct ImageMagickRunner: MediaToolRunner {

    //
    // Identifier for this runner, surfaced in diagnostics.
    //
    let id = "ios-imagemagick"

    //
    // Serialises every ImageMagick call. The shim redirects the process-global stdout file descriptor
    // around MagickCommandGenesis to capture text output, so concurrent calls across engine-pool slots
    // must not overlap. FFmpegKit captures per session and needs no such lock.
    //
    private static let lock = NSLock()

    //
    // Monotonic counter used to give each call a unique capture file name, so serialised calls never
    // read a stale capture (belt-and-braces alongside the lock).
    //
    private static var callCounter: Int = 0

    //
    // Runs a magick argv in-process. Prepends "magick" (the shared TypeScript argv omits the tool
    // name), redirects stdout to a per-call capture file inside the shim, and returns the captured
    // text with the dispatcher's exit code.
    //
    func imagemagick(_ args: [String]) -> ToolResult {
        #if IMAGEMAGICK_LINKED
        ImageMagickRunner.lock.lock()
        defer { ImageMagickRunner.lock.unlock() }

        ImageMagickRunner.callCounter += 1
        let captureName = "magick-capture-\(ImageMagickRunner.callCounter).txt"
        let capturePath = (NSTemporaryDirectory() as NSString).appendingPathComponent(captureName)

        // The magick dispatcher expects argv[0] == "magick".
        let argv = ["magick"] + args
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer {
            for pointer in cargs where pointer != nil {
                free(pointer)
            }
        }

        let code = run_magick(Int32(argv.count), &cargs, capturePath)
        let output = (try? String(contentsOfFile: capturePath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: capturePath)
        return ToolResult(exitCode: Int(code), output: output)
        #else
        return ToolResult(exitCode: -1, output: "ImageMagick not linked (enable IMAGEMAGICK_LINKED)")
        #endif
    }

    //
    // Not handled here; the bridge routes ffprobe to the FFmpegKit runner.
    //
    func ffprobe(_ args: [String]) -> ToolResult {
        return ToolResult(exitCode: -1, output: "ffprobe not handled by ImageMagickRunner")
    }

    //
    // Not handled here; the bridge routes ffmpeg to the FFmpegKit runner.
    //
    func ffmpeg(_ args: [String]) -> ToolResult {
        return ToolResult(exitCode: -1, output: "ffmpeg not handled by ImageMagickRunner")
    }
}
