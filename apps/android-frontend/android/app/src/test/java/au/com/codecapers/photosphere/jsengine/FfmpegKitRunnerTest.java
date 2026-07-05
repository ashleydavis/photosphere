package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

//
// Plain-JVM unit tests for the FFmpegKit runner's deterministic contract: its id, its routing of
// imagemagick to the "not handled" result, and its reflective "not linked" fallback for ffprobe/ffmpeg
// when the FFmpegKit native dependency cannot run in the unit-test JVM. The real ffmpeg/ffprobe output
// is exercised by the asset-processing smoke test on device.
//
public final class FfmpegKitRunnerTest {

    //
    // The runner under test; it is stateless so a single instance is reused.
    //
    private final FfmpegKitRunner runner = new FfmpegKitRunner();

    @Test
    public void idIsAndroidFfmpegKitFork() {
        assertEquals("android-ffmpeg-kit-fork", runner.id());
    }

    @Test
    public void imagemagickIsNotHandledByFfmpegKitRunner() {
        ToolResult result = runner.imagemagick(new String[] { "info:" });
        assertEquals(-1, result.exitCode);
        assertEquals("imagemagick not handled by FfmpegKitRunner", result.output);
    }

    @Test
    public void ffprobeReportsNotLinkedWithoutTheDependency() {
        ToolResult result = runner.ffprobe(new String[] { "-show_format", "in.mp4" });
        assertEquals(-1, result.exitCode);
        assertTrue(result.output.contains("not linked"));
    }

    @Test
    public void ffmpegReportsNotLinkedWithoutTheDependency() {
        ToolResult result = runner.ffmpeg(new String[] { "-i", "in.mp4", "out.jpg" });
        assertEquals(-1, result.exitCode);
        assertTrue(result.output.contains("not linked"));
    }
}
