package au.com.codecapers.photosphere.jsengine;

//
// The native runner contract. A concrete runner wraps one tool library (FFmpegKit, the ImageMagick
// JNI shim) and runs argv in-process. The host bridge routes host.imageMagick to the ImageMagick
// runner and host.ffmpeg / host.ffprobe to the FFmpegKit runner.
//
public interface MediaToolRunner {

    //
    // Short identifier for the active runner (e.g. "android-imagemagick", "android-ffmpeg-kit-fork").
    //
    String id();

    //
    // Runs an ffprobe argv (no leading "ffprobe"); metadata is returned in output.
    //
    ToolResult ffprobe(String[] args);

    //
    // Runs an ffmpeg argv (no leading "ffmpeg"); the produced file is written directly.
    //
    ToolResult ffmpeg(String[] args);

    //
    // Runs a magick argv (the runner prepends "magick"); covers all ImageMagick operations.
    //
    ToolResult imagemagick(String[] args);
}
