package au.com.codecapers.photosphere.ziggy;

//
// The result of running one media tool: an exit code and what the tool printed. It is answered to the core as the JSON
// { exitCode, output }.
//
public class ToolResult {

    //
    // Native exit code; 0 == success.
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
