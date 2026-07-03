package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;

//
// Plain-JVM unit tests for the media host-function marshalling: argv JSON parsing, sandbox path
// resolution, and the runMediaTool orchestration (exercised with a fake runner so no native library
// is needed). The actual ImageMagick/ffmpeg output is exercised by the asset-processing smoke test on
// the emulator; here the runner is a stand-in that records the resolved argv.
//
public final class MediaHostFunctionsTest {

    //
    // A fresh temporary storage root per test, used as the sandbox root.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // A fake runner that records the argv it was handed and returns a canned result.
    //
    private static final class RecordingRunner implements MediaToolRunner {
        String[] lastArgv;
        final int exitCode;
        final String output;

        RecordingRunner(int exitCode, String output) {
            this.exitCode = exitCode;
            this.output = output;
        }

        @Override
        public String id() {
            return "recording";
        }

        @Override
        public ToolResult imagemagick(String[] args) {
            lastArgv = args;
            return new ToolResult(exitCode, output);
        }

        @Override
        public ToolResult ffmpeg(String[] args) {
            lastArgv = args;
            return new ToolResult(exitCode, output);
        }

        @Override
        public ToolResult ffprobe(String[] args) {
            lastArgv = args;
            return new ToolResult(exitCode, output);
        }
    }

    //
    // parseJsonStringArray decodes a flat JSON string array, including escaped characters.
    //
    @Test
    public void parseJsonStringArrayDecodesElements() {
        String[] parsed = HostFunctions.parseJsonStringArray("[\"a.jpg\",\"-resize\",\"300x300\",\"jpeg:out.jpg\"]");
        assertArrayEquals(new String[] { "a.jpg", "-resize", "300x300", "jpeg:out.jpg" }, parsed);

        String[] escaped = HostFunctions.parseJsonStringArray("[\"a\\\"b\",\"c\\\\d\",\"e\\/f\"]");
        assertArrayEquals(new String[] { "a\"b", "c\\d", "e/f" }, escaped);
    }

    //
    // resolveMediaToken leaves flag/geometry/pseudo tokens unchanged.
    //
    @Test
    public void resolveLeavesNonPathTokensUnchanged() {
        File root = temporaryFolder.getRoot();
        assertEquals("-resize", HostFunctions.resolveMediaToken(root, "-resize"));
        assertEquals("300x300", HostFunctions.resolveMediaToken(root, "300x300"));
        assertEquals("info:", HostFunctions.resolveMediaToken(root, "info:"));
        assertEquals("histogram:info:", HostFunctions.resolveMediaToken(root, "histogram:info:"));
    }

    //
    // resolveMediaToken makes a relative path absolute under the root, preserving an encoder prefix.
    //
    @Test
    public void resolveMakesPathsAbsolute() {
        File root = temporaryFolder.getRoot();
        assertEquals(new File(root, "tmp/a.jpg").getAbsolutePath(),
            HostFunctions.resolveMediaToken(root, "tmp/a.jpg"));
        assertEquals("jpeg:" + new File(root, "tmp/out.jpg").getAbsolutePath(),
            HostFunctions.resolveMediaToken(root, "jpeg:tmp/out.jpg"));
    }

    //
    // resolveMediaToken rejects a path that escapes the sandbox root.
    //
    @Test
    public void resolveRejectsEscapingPaths() {
        File root = temporaryFolder.getRoot();
        try {
            HostFunctions.resolveMediaToken(root, "../escape/a.jpg");
            fail("expected a sandbox rejection");
        }
        catch (RuntimeException expected) {
            // expected
        }
    }

    //
    // runMediaTool resolves the argv, runs the runner, and returns the { exitCode, output } JSON.
    //
    @Test
    public void runMediaToolResolvesArgvAndReturnsJson() {
        File root = temporaryFolder.getRoot();
        RecordingRunner runner = new RecordingRunner(0, "800 600");
        String argvJson = "[\"tmp/a.jpg\",\"-format\",\"%w %h\",\"info:\"]";

        String result = HostFunctions.runMediaTool(root, runner, 0, argvJson);

        assertEquals(new File(root, "tmp/a.jpg").getAbsolutePath(), runner.lastArgv[0]);
        assertEquals("info:", runner.lastArgv[3]);
        assertTrue(result.contains("\"exitCode\":0"));
        assertTrue(result.contains("\"output\":\"800 600\""));
    }

    //
    // runMediaTool returns an @@HOSTERR@@ envelope (never throws) when a path escapes the sandbox.
    //
    @Test
    public void runMediaToolReturnsEnvelopeOnBadPath() {
        File root = temporaryFolder.getRoot();
        RecordingRunner runner = new RecordingRunner(0, "");
        String result = HostFunctions.runMediaTool(root, runner, 0, "[\"../escape.jpg\"]");
        assertTrue(result.startsWith("@@HOSTERR@@"));
    }
}
