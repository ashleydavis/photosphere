package au.com.codecapers.photosphere.jsengine;

import java.lang.reflect.Method;

//
// Android ffmpeg/ffprobe runner backed by an FFmpegKit fork (for example the 16KB-page-aligned
// com.moizhassan.ffmpeg:ffmpeg-kit-16kb fork). The com.arthenica FFmpegKit API is reached by
// reflection so this class compiles whether or not the FFmpegKit dependency is on the classpath: when
// the dependency is present the argv runs in-process; when it is absent every call returns a "not
// linked" result rather than failing the build or crashing the engine. This runner handles only
// ffprobe/ffmpeg; imagemagick stays on its own runner.
//
public class FfmpegKitRunner implements MediaToolRunner {

    //
    // Identifier for this runner, surfaced in diagnostics.
    //
    public static final String ID = "android-ffmpeg-kit-fork";

    //
    // Runner id.
    //
    @Override
    public String id() {
        return ID;
    }

    //
    // Runs an ffprobe argv in-process and returns its exit code and captured output (the ffprobe JSON).
    //
    @Override
    public ToolResult ffprobe(String[] args) {
        return runViaReflection("com.arthenica.ffmpegkit.FFprobeKit", args, "ffprobe");
    }

    //
    // Runs an ffmpeg argv in-process (e.g. the screenshot extraction) and returns its exit code.
    //
    @Override
    public ToolResult ffmpeg(String[] args) {
        return runViaReflection("com.arthenica.ffmpegkit.FFmpegKit", args, "ffmpeg");
    }

    //
    // Not handled here; the bridge routes imagemagick to the ImageMagick runner.
    //
    @Override
    public ToolResult imagemagick(String[] args) {
        return new ToolResult(-1, "imagemagick not handled by FfmpegKitRunner");
    }

    //
    // Invokes <kitClassName>.executeWithArguments(String[]) reflectively, then reads
    // session.getReturnCode().getValue() and session.getOutput(). Any reflection failure (the
    // dependency is absent) yields a "not linked" result.
    //
    private ToolResult runViaReflection(String kitClassName, String[] args, String toolName) {
        try {
            Class<?> kitClass = Class.forName(kitClassName);
            Method execute = kitClass.getMethod("executeWithArguments", String[].class);
            Object session = execute.invoke(null, (Object) args);
            if (session == null) {
                return new ToolResult(-1, toolName + ": null session");
            }

            Object returnCode = session.getClass().getMethod("getReturnCode").invoke(session);
            int exitCode = -1;
            if (returnCode != null) {
                Object value = returnCode.getClass().getMethod("getValue").invoke(returnCode);
                if (value instanceof Integer) {
                    exitCode = (Integer) value;
                }
            }

            Object output = session.getClass().getMethod("getOutput").invoke(session);
            String outputText = output instanceof String ? (String) output : "";
            return new ToolResult(exitCode, outputText);
        }
        catch (Throwable error) {
            return new ToolResult(-1, toolName + " not linked (FFmpegKit dependency not present)");
        }
    }
}
