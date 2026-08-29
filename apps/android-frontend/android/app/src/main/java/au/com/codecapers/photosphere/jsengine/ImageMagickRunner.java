package au.com.codecapers.photosphere.jsengine;

import java.io.File;

//
// Android ImageMagick runner. Calls the in-process `magick` dispatcher through the run_magick JNI
// shim (see cpp/run_magick.c), backed by the prebuilt Android-ImageMagick7 shared libraries in
// jniLibs. Handles every ImageMagick operation via the single argv method; ffprobe/ffmpeg go to the
// FFmpegKit runner. The shim captures stdout (identify/EXIF/dominant/histogram text) into a file in
// the cache dir, which is passed in per call.
//
// The native libraries are loaded lazily; if they are not vendored yet, loading fails softly and
// every call returns a "not linked" result rather than crashing the engine.
//
public class ImageMagickRunner implements MediaToolRunner {

    //
    // Identifier for this runner, surfaced in diagnostics.
    //
    public static final String ID = "android-imagemagick";

    //
    // Whether the native libraries loaded successfully (set once by ensureLoaded).
    //
    private static boolean loaded = false;

    //
    // Whether an attempt to load the native libraries has already been made.
    //
    private static boolean loadAttempted = false;

    //
    // Serialises every ImageMagick call. The JNI shim redirects the process-global stdout file
    // descriptor around MagickCommandGenesis, so concurrent calls across engine-pool slots must not
    // overlap. FFmpegKit captures per session and needs no such lock.
    //
    private static final Object LOCK = new Object();

    //
    // Monotonic counter used to give each call a unique capture file name.
    //
    private static int callCounter = 0;

    //
    // The writable cache directory the per-call stdout capture file is written into.
    //
    private final File cacheDir;

    //
    // Attempts to load the native libraries in dependency order, once. libomp is only present in some
    // builds so its absence is not fatal; a failure to load the ImageMagick libraries leaves the
    // runner in the "not linked" state.
    //
    private static synchronized void ensureLoaded() {
        if (loadAttempted) {
            return;
        }
        loadAttempted = true;
        try {
            try {
                System.loadLibrary("omp");
            }
            catch (Throwable ignored) {
            }
            System.loadLibrary("magickcore-7");
            System.loadLibrary("magickwand-7");
            System.loadLibrary("run_magick");
            loaded = true;
        }
        catch (Throwable error) {
            loaded = false;
        }
    }

    //
    // Constructs the runner with the cache dir used for stdout capture, attempting the native load.
    //
    public ImageMagickRunner(File cacheDir) {
        this.cacheDir = cacheDir;
        ensureLoaded();
    }

    //
    // Native entry: argv (with "magick" at index 0) + a writable capture file -> Object[]{ Integer
    // exit, String capturedStdout }.
    //
    private native Object[] nativeMagick(String[] argv, String capturePath);

    //
    // Runner id.
    //
    @Override
    public String id() {
        return ID;
    }

    //
    // Runs a magick argv in-process. Prepends "magick" (the shared TypeScript argv omits the tool
    // name), serialises the call, and returns the captured text with the dispatcher's exit code. When
    // the native libraries are not vendored, returns a "not linked" result.
    //
    @Override
    public ToolResult imagemagick(String[] args) {
        if (!loaded) {
            return new ToolResult(-1, "ImageMagick not linked (native libraries not vendored)");
        }

        synchronized (LOCK) {
            callCounter += 1;
            String[] argv = new String[args.length + 1];
            argv[0] = "magick";
            System.arraycopy(args, 0, argv, 1, args.length);

            // The bundled build takes the app down on a WebP, so Android's decoder converts one to a
            // PNG first and ImageMagick reads that instead. See WebPInput.
            File converted = null;
            int inputIndex = WebPInput.inputPathIndex(args);
            if (inputIndex >= 0) {
                File input = new File(args[inputIndex]);
                if (input.isFile() && WebPInput.isWebP(input)) {
                    converted = WebPInput.decodeToPng(input, cacheDir);
                    argv[inputIndex + 1] = converted.getAbsolutePath();
                }
            }

            String capturePath = new File(cacheDir, "magick-capture-" + callCounter + ".txt").getAbsolutePath();
            Object[] result = nativeMagick(argv, capturePath);
            int exit = (result != null && result[0] instanceof Integer) ? (Integer) result[0] : 1;
            String output = (result != null && result[1] instanceof String) ? (String) result[1] : "";
            new File(capturePath).delete();
            if (converted != null) {
                converted.delete();
            }
            return new ToolResult(exit, output);
        }
    }

    //
    // Not handled here; the bridge routes ffprobe to the FFmpegKit runner.
    //
    @Override
    public ToolResult ffprobe(String[] args) {
        return new ToolResult(-1, "ffprobe not handled by ImageMagickRunner");
    }

    //
    // Not handled here; the bridge routes ffmpeg to the FFmpegKit runner.
    //
    @Override
    public ToolResult ffmpeg(String[] args) {
        return new ToolResult(-1, "ffmpeg not handled by ImageMagickRunner");
    }
}
