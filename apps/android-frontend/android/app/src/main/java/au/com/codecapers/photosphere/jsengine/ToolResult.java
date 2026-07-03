package au.com.codecapers.photosphere.jsengine;

//
// The decoded result of running one media tool invocation, mirroring the JS IMediaResult / the
// desktop tool output: an exit code and the captured stdout. The host bridge serialises this to the
// JSON string { exitCode, output } the mobile runMediaTool helper decodes.
//
public class ToolResult {

    //
    // Native/process exit code; 0 == success.
    //
    public final int exitCode;

    //
    // Captured stdout / metadata / logs (e.g. ffprobe JSON, identify text).
    //
    public final String output;

    //
    // Constructs a result, normalising a null output to the empty string.
    //
    public ToolResult(int exitCode, String output) {
        this.exitCode = exitCode;
        this.output = output != null ? output : "";
    }
}
