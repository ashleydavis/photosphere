package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

//
// Plain-JVM unit tests for the ToolResult value holder. The only behaviour beyond field assignment is
// that a null output is normalised to the empty string, so a runner that produced no output never
// crosses the bridge as a null.
//
public final class ToolResultTest {

    @Test
    public void retainsExitCodeAndOutput() {
        ToolResult result = new ToolResult(0, "800 600");
        assertEquals(0, result.exitCode);
        assertEquals("800 600", result.output);
    }

    @Test
    public void normalisesNullOutputToEmptyString() {
        ToolResult result = new ToolResult(-1, null);
        assertEquals(-1, result.exitCode);
        assertEquals("", result.output);
    }
}
