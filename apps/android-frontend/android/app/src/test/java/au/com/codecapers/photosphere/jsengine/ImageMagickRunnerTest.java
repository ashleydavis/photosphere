package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

//
// Plain-JVM unit tests for the ImageMagick runner's deterministic contract: its id and its routing of
// ffprobe/ffmpeg to the "not handled" result. In the unit-test JVM the native ImageMagick libraries
// are not present, so System.loadLibrary fails softly and imagemagick() reports "not linked" rather
// than crashing. The real ImageMagick output is exercised by the asset-processing smoke test on device.
//
public final class ImageMagickRunnerTest {

    //
    // A fresh temporary cache dir per test, used for the runner's stdout-capture files.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // Builds a runner backed by the temporary cache dir.
    //
    private ImageMagickRunner newRunner() {
        return new ImageMagickRunner(temporaryFolder.getRoot());
    }

    @Test
    public void idIsAndroidImageMagick() {
        assertEquals("android-imagemagick", newRunner().id());
    }

    @Test
    public void imagemagickReportsNotLinkedWithoutNativeLibraries() {
        ToolResult result = newRunner().imagemagick(new String[] { "info:" });
        assertEquals(-1, result.exitCode);
        assertTrue(result.output.contains("not linked"));
    }

    @Test
    public void ffprobeIsNotHandledByImageMagickRunner() {
        ToolResult result = newRunner().ffprobe(new String[] { "-show_format" });
        assertEquals(-1, result.exitCode);
        assertEquals("ffprobe not handled by ImageMagickRunner", result.output);
    }

    @Test
    public void ffmpegIsNotHandledByImageMagickRunner() {
        ToolResult result = newRunner().ffmpeg(new String[] { "-i", "in.mp4" });
        assertEquals(-1, result.exitCode);
        assertEquals("ffmpeg not handled by ImageMagickRunner", result.output);
    }
}
