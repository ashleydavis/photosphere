package au.com.codecapers.photosphere.ziggy;

import dev.ziggy.shell.HostRequestException;
import java.io.File;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

//
// Answers the core's requests to run ImageMagick, ffmpeg and ffprobe, which Android has no programs for. Each request is the JSON
// {"args": [...]} (the tool's arguments, not its name) and is answered with {"exitCode": number, "output": text}. A tool that ends with
// a non-zero code is still an answer: the core decides what that means.
//
public final class MediaTools {
    private final ImageMagickRunner imageMagick;
    private final FfmpegKitRunner ffmpegKit;

    public MediaTools(File cacheDir) {
        this.imageMagick = new ImageMagickRunner(cacheDir);
        this.ffmpegKit = new FfmpegKitRunner();
    }

    //
    // Runs the tool the method names (runMagick, runFfmpeg or runFfprobe) with the request's arguments.
    //
    public String run(String method, String requestJson) throws HostRequestException {
        try {
            JSONArray argsJson = new JSONObject(requestJson).getJSONArray("args");
            String[] args = new String[argsJson.length()];
            for (int index = 0; index < args.length; index++) {
                args[index] = argsJson.getString(index);
            }
            ToolResult result;
            switch (method) {
                case "runMagick":
                    result = imageMagick.run(args);
                    break;
                case "runFfmpeg":
                    result = ffmpegKit.ffmpeg(args);
                    break;
                case "runFfprobe":
                    result = ffmpegKit.ffprobe(args);
                    break;
                default:
                    throw new HostRequestException("There is no media tool for \"" + method + "\".");
            }
            return new JSONObject()
                .put("exitCode", result.exitCode)
                .put("output", result.output)
                .toString();
        } catch (JSONException error) {
            throw new HostRequestException("The request " + method + " was not understood: " + error.getMessage(), error);
        }
    }
}
