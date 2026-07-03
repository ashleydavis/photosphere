package au.com.codecapers.photosphere.jsengine;

import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;

//
// Static helpers shared by the host bridge across all engine contexts. The NOT IMPLEMENTED
// loud-failure helper plus the native-backed fs READ functions live here. The fs functions are
// deliberately written against plain java.io (no android.* or java.nio.file APIs) so they work on
// the project's minSdk (22, below the API 26 that java.nio.file.Files / java.util.Base64 require)
// AND can be unit-tested on a plain JVM without Android stubs. These helpers are stateless and
// thread-safe so the engine pool can call them concurrently from multiple engine threads.
//
public final class HostFunctions {

    //
    // Log tag used for all native host-function diagnostics.
    //
    private static final String LOG_TAG = "JsEngineHost";

    //
    // The platform string handed to the embedded worker as host.platform.
    //
    public static final String PLATFORM = "android";

    //
    // Standard base64 alphabet (RFC 4648). Used by the portable base64 encoder below so file bytes
    // cross the bridge as a base64 string the JS-side Buffer decodes.
    //
    private static final char[] BASE64_ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toCharArray();

    //
    // Reverse lookup for base64 decoding: maps an ASCII character code to its 6-bit value, or -1 for
    // non-alphabet characters (padding and whitespace are skipped by the decoder).
    //
    private static final int[] BASE64_REVERSE = buildBase64Reverse();

    //
    // Buffer size used when reading files in a streaming loop.
    //
    private static final int READ_BUFFER_SIZE = 8192;

    //
    // Marker prefix used in the exception message when an exclusive write hits an existing file, so
    // the JS fs shim can map it to a Node-style EEXIST error code.
    //
    private static final String EEXIST_PREFIX = "EEXIST";

    //
    // Private constructor: static helper class, never instantiated.
    //
    private HostFunctions() {
    }

    //
    // Builds the exact, verbatim NOT IMPLEMENTED error message for a host function that native
    // has not implemented yet, logs it at error level so it is visible during native debugging,
    // and returns a RuntimeException carrying that message so callers can throw it. The message
    // format is contractually identical to the iOS side and the JS-side stubs: changing it breaks
    // the loud-failure guarantee.
    //
    public static RuntimeException notImplemented(String name) {
        String message = "NOT IMPLEMENTED: native host function \"" + name
            + "\" is not implemented yet on " + PLATFORM + ". Implement it ASAP.";
        Log.e(LOG_TAG, message);
        return new RuntimeException(message);
    }

    //
    // host.sha256(path): hashing a file is a Node.js crypto capability that this infrastructure
    // plan deliberately does not implement natively. It reports NOT IMPLEMENTED until a later plan
    // provides the native hashing host function. The arguments are accepted only so the host-bridge
    // signature stays stable for when the real implementation lands.
    //
    public static String sha256(File storageRoot, String candidatePath) {
        throw notImplemented("sha256");
    }

    //
    // host.fsReadFile(path): reads a file under the sandbox root and returns its bytes as a base64
    // string (the marshalling format the mobile fs shim decodes). Returns null when the path does not
    // exist or is not a regular file, which the shim surfaces as an ENOENT error. The read path only
    // ever reads small database metadata files, so a whole-file read is appropriate.
    //
    public static String fsReadFile(File storageRoot, String candidatePath) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (!target.exists() || !target.isFile()) {
            return null;
        }

        try {
            return base64Encode(readAllBytes(target));
        }
        catch (IOException error) {
            throw new RuntimeException("fsReadFile failed for \"" + candidatePath + "\": " + error.getMessage(), error);
        }
    }

    //
    // host.fsAccess(path): returns true when a file or directory exists at the sandboxed path. Used
    // by node-utils pathExists, which branches on existence.
    //
    public static boolean fsAccess(File storageRoot, String candidatePath) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        return target.exists();
    }

    //
    // host.fsStat(path): returns a JSON string { size, mtimeMs, isFile, isDirectory } for the
    // sandboxed path, or null when it does not exist (surfaced as ENOENT by the shim). The JSON is
    // built by hand (only numbers and booleans, no string values) to avoid an Android-only JSON
    // dependency and keep this unit-testable on a plain JVM.
    //
    public static String fsStat(File storageRoot, String candidatePath) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (!target.exists()) {
            return null;
        }

        return "{\"size\":" + target.length()
            + ",\"mtimeMs\":" + target.lastModified()
            + ",\"isFile\":" + target.isFile()
            + ",\"isDirectory\":" + target.isDirectory()
            + "}";
    }

    //
    // host.fsReaddir(path): returns a JSON string array of { name, isDirectory } entries for a
    // directory under the sandbox root, or null when the directory does not exist. The shim adapts
    // this to plain names or Dirent objects depending on the withFileTypes option. Entry names are
    // JSON-escaped so names with quotes/backslashes/control characters cannot corrupt the payload.
    //
    public static String fsReaddir(File storageRoot, String candidatePath) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (!target.exists() || !target.isDirectory()) {
            return null;
        }

        File[] entries = target.listFiles();
        StringBuilder result = new StringBuilder("[");
        if (entries != null) {
            for (int index = 0; index < entries.length; index++) {
                if (index > 0) {
                    result.append(",");
                }
                result.append("{\"name\":\"")
                    .append(jsonEscape(entries[index].getName()))
                    .append("\",\"isDirectory\":")
                    .append(entries[index].isDirectory())
                    .append("}");
            }
        }
        result.append("]");
        return result.toString();
    }

    //
    // host.fsWriteFile(path, base64, exclusive): writes the base64-decoded bytes to the sandboxed
    // path, creating parent directories as needed. When exclusive is true (the Node 'wx' flag) and
    // the file already exists, it throws an EEXIST-marked error so the JS shim surfaces EEXIST (used
    // by the write-lock). The write is whole-file, matching the mobile read model.
    //
    public static void fsWriteFile(File storageRoot, String candidatePath, String base64, boolean exclusive) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (exclusive && target.exists()) {
            throw new RuntimeException(EEXIST_PREFIX + ": file already exists: " + candidatePath);
        }

        File parent = target.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }

        byte[] data = base64Decode(base64);
        try (FileOutputStream output = new FileOutputStream(target)) {
            output.write(data);
        }
        catch (IOException error) {
            throw new RuntimeException("fsWriteFile failed for \"" + candidatePath + "\": " + error.getMessage(), error);
        }
    }

    //
    // host.fsMkdir(path, recursive): creates a directory under the sandbox root. With recursive true
    // (the only mode the storage layer uses) it creates missing parents and is a no-op when the
    // directory already exists, matching Node's fs.mkdir({ recursive: true }).
    //
    public static void fsMkdir(File storageRoot, String candidatePath, boolean recursive) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (target.isDirectory()) {
            return;
        }

        boolean created = recursive ? target.mkdirs() : target.mkdir();
        if (!created && !target.isDirectory()) {
            throw new RuntimeException("fsMkdir failed for \"" + candidatePath + "\"");
        }
    }

    //
    // host.fsRename(srcPath, destPath): renames/moves a sandboxed file. Removes an existing
    // destination first (Node rename overwrites), and falls back to copy+delete when a direct rename
    // is not possible (for example across directories). Both paths are sandbox-validated.
    //
    public static void fsRename(File storageRoot, String srcPath, String destPath) {
        File source = PathSandbox.resolveWithin(storageRoot, srcPath);
        File destination = PathSandbox.resolveWithin(storageRoot, destPath);

        File parent = destination.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        if (destination.exists()) {
            destination.delete();
        }

        if (source.renameTo(destination)) {
            return;
        }

        // Fallback: copy the bytes then remove the source.
        try {
            byte[] data = readAllBytes(source);
            try (FileOutputStream output = new FileOutputStream(destination)) {
                output.write(data);
            }
            source.delete();
        }
        catch (IOException error) {
            throw new RuntimeException("fsRename failed for \"" + srcPath + "\" -> \"" + destPath + "\": " + error.getMessage(), error);
        }
    }

    //
    // host.fsUnlink(path): deletes a sandboxed file. Throws an ENOENT-marked error when the file does
    // not exist (callers such as the write-lock release and node-utils remove() catch ENOENT).
    //
    public static void fsUnlink(File storageRoot, String candidatePath) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (!target.exists()) {
            throw new RuntimeException("ENOENT: no such file or directory, unlink '" + candidatePath + "'");
        }
        if (!target.delete()) {
            throw new RuntimeException("fsUnlink failed for \"" + candidatePath + "\"");
        }
    }

    //
    // host.fsRm(path, recursive, force): deletes a sandboxed file or directory tree. With force, a
    // missing path is a no-op; otherwise a missing path throws ENOENT. Directories are removed
    // recursively (the storage layer always uses recursive removal).
    //
    public static void fsRm(File storageRoot, String candidatePath, boolean recursive, boolean force) {
        File target = PathSandbox.resolveWithin(storageRoot, candidatePath);
        if (!target.exists()) {
            if (force) {
                return;
            }
            throw new RuntimeException("ENOENT: no such file or directory, rm '" + candidatePath + "'");
        }
        deleteRecursively(target);
    }

    //
    // Recursively deletes a file or directory tree.
    //
    private static void deleteRecursively(File target) {
        if (target.isDirectory()) {
            File[] children = target.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        target.delete();
    }

    //
    // Reads a whole file into a byte array using plain java.io (FileInputStream), so it works below
    // API 26 where java.nio.file.Files is unavailable. Package-private so unit tests can exercise it.
    //
    static byte[] readAllBytes(File target) throws IOException {
        try (FileInputStream input = new FileInputStream(target)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[READ_BUFFER_SIZE];
            int bytesRead = input.read(buffer);
            while (bytesRead != -1) {
                output.write(buffer, 0, bytesRead);
                bytesRead = input.read(buffer);
            }
            return output.toByteArray();
        }
    }

    //
    // Encodes bytes as standard base64 (RFC 4648, with padding, no line wrapping). Hand-rolled so it
    // works on every API level (java.util.Base64 needs API 26, android.util.Base64 cannot be used in
    // plain-JVM unit tests). Package-private so unit tests can verify it against java.util.Base64.
    //
    static String base64Encode(byte[] data) {
        StringBuilder builder = new StringBuilder(((data.length + 2) / 3) * 4);
        int index = 0;
        while (index + 3 <= data.length) {
            int chunk = ((data[index] & 0xFF) << 16) | ((data[index + 1] & 0xFF) << 8) | (data[index + 2] & 0xFF);
            builder.append(BASE64_ALPHABET[(chunk >> 18) & 0x3F]);
            builder.append(BASE64_ALPHABET[(chunk >> 12) & 0x3F]);
            builder.append(BASE64_ALPHABET[(chunk >> 6) & 0x3F]);
            builder.append(BASE64_ALPHABET[chunk & 0x3F]);
            index += 3;
        }

        int remaining = data.length - index;
        if (remaining == 1) {
            int chunk = (data[index] & 0xFF) << 16;
            builder.append(BASE64_ALPHABET[(chunk >> 18) & 0x3F]);
            builder.append(BASE64_ALPHABET[(chunk >> 12) & 0x3F]);
            builder.append("==");
        }
        else if (remaining == 2) {
            int chunk = ((data[index] & 0xFF) << 16) | ((data[index + 1] & 0xFF) << 8);
            builder.append(BASE64_ALPHABET[(chunk >> 18) & 0x3F]);
            builder.append(BASE64_ALPHABET[(chunk >> 12) & 0x3F]);
            builder.append(BASE64_ALPHABET[(chunk >> 6) & 0x3F]);
            builder.append("=");
        }

        return builder.toString();
    }

    //
    // Builds an error-envelope string (format shared with the JS host-access shim and iOS) so a native
    // failure crosses the engine bridge as a value the shim decodes and throws, never as a Java
    // exception (which the QuickJS wrapper does not convert and would crash on). The code segment is
    // recognised by the shim (EEXIST / ENOENT); other failures use an empty code.
    //
    public static String hostErrorEnvelope(Throwable error) {
        String message = error.getMessage();
        if (message == null) {
            message = error.toString();
        }
        String code = message.contains("EEXIST") ? "EEXIST" : (message.contains("ENOENT") ? "ENOENT" : "");
        return "@@HOSTERR@@" + code + ":" + message;
    }

    //
    // Runs a media tool (host.imageMagick / host.ffmpeg / host.ffprobe): decodes the JSON-encoded
    // argv, sandbox-resolves its path tokens to absolute paths, runs the given runner method, and
    // returns the JSON string { exitCode, output }. On any failure (bad JSON, a path that escapes the
    // sandbox) it returns an @@HOSTERR@@ envelope string rather than throwing across the engine bridge.
    // The runner method is selected by kind: 0 = imagemagick, 1 = ffmpeg, 2 = ffprobe.
    //
    public static String runMediaTool(File storageRoot, MediaToolRunner runner, int kind, String argvJson) {
        try {
            String[] rawArgv = parseJsonStringArray(argvJson);
            String[] resolvedArgv = new String[rawArgv.length];
            for (int index = 0; index < rawArgv.length; index++) {
                resolvedArgv[index] = resolveMediaToken(storageRoot, rawArgv[index]);
            }

            ToolResult result;
            if (kind == 0) {
                result = runner.imagemagick(resolvedArgv);
            }
            else if (kind == 1) {
                result = runner.ffmpeg(resolvedArgv);
            }
            else {
                result = runner.ffprobe(resolvedArgv);
            }

            return "{\"exitCode\":" + result.exitCode + ",\"output\":\"" + jsonEscape(result.output) + "\"}";
        }
        catch (Throwable error) {
            return hostErrorEnvelope(error);
        }
    }

    //
    // Resolves a single argv token. A token that names a sandbox-relative path (it contains a path
    // separator, optionally after an ImageMagick "encoder:" prefix like "jpeg:tmp/out.jpg") is
    // resolved to its absolute path under the storage root via PathSandbox, so the native tool reads
    // and writes real files; the sandbox rejects absolute paths and `..` traversal. Non-path tokens
    // (flags, geometry, "info:", "histogram:info:") are returned unchanged.
    //
    static String resolveMediaToken(File storageRoot, String token) {
        String prefix = "";
        String pathPart = token;
        int colon = token.indexOf(':');
        if (colon >= 0 && token.indexOf('/', colon) > colon) {
            prefix = token.substring(0, colon + 1);
            pathPart = token.substring(colon + 1);
        }

        if (pathPart.indexOf('/') < 0) {
            return token;
        }

        File resolved = PathSandbox.resolveWithin(storageRoot, pathPart);
        return prefix + resolved.getAbsolutePath();
    }

    //
    // Parses a JSON array of strings (the media argv) into a String[]. Hand-rolled (no org.json) so it
    // is unit-testable on a plain JVM, matching the rest of this class. Handles the standard JSON
    // string escapes. Throws when the input is not a JSON array of strings.
    //
    static String[] parseJsonStringArray(String json) {
        java.util.List<String> items = new java.util.ArrayList<>();
        int index = 0;
        int length = json.length();
        while (index < length && Character.isWhitespace(json.charAt(index))) {
            index++;
        }
        if (index >= length || json.charAt(index) != '[') {
            throw new RuntimeException("media argv: expected '['");
        }
        index++;

        while (true) {
            while (index < length && Character.isWhitespace(json.charAt(index))) {
                index++;
            }
            if (index >= length) {
                throw new RuntimeException("media argv: unterminated array");
            }
            char current = json.charAt(index);
            if (current == ']') {
                index++;
                break;
            }
            if (current == ',') {
                index++;
                continue;
            }
            if (current != '"') {
                throw new RuntimeException("media argv: expected string element");
            }

            index++;
            StringBuilder builder = new StringBuilder();
            while (index < length) {
                char character = json.charAt(index);
                if (character == '"') {
                    index++;
                    break;
                }
                if (character == '\\') {
                    index++;
                    if (index >= length) {
                        throw new RuntimeException("media argv: dangling escape");
                    }
                    char escape = json.charAt(index);
                    switch (escape) {
                        case '"': builder.append('"'); break;
                        case '\\': builder.append('\\'); break;
                        case '/': builder.append('/'); break;
                        case 'n': builder.append('\n'); break;
                        case 'r': builder.append('\r'); break;
                        case 't': builder.append('\t'); break;
                        case 'b': builder.append('\b'); break;
                        case 'f': builder.append('\f'); break;
                        case 'u':
                            String hex = json.substring(index + 1, index + 5);
                            builder.append((char) Integer.parseInt(hex, 16));
                            index += 4;
                            break;
                        default:
                            throw new RuntimeException("media argv: bad escape \\" + escape);
                    }
                    index++;
                }
                else {
                    builder.append(character);
                    index++;
                }
            }
            items.add(builder.toString());
        }

        return items.toArray(new String[0]);
    }

    //
    // Builds the base64 decode reverse-lookup table (ASCII code -> 6-bit value, -1 otherwise).
    //
    private static int[] buildBase64Reverse() {
        int[] reverse = new int[128];
        for (int index = 0; index < reverse.length; index++) {
            reverse[index] = -1;
        }
        for (int index = 0; index < BASE64_ALPHABET.length; index++) {
            reverse[BASE64_ALPHABET[index]] = index;
        }
        return reverse;
    }

    //
    // Decodes a standard base64 string (RFC 4648) to bytes. Padding and any non-alphabet characters
    // (including whitespace/newlines) are skipped. Hand-rolled so it works on every API level and is
    // unit-testable on a plain JVM. Package-private so unit tests can verify it against java.util.Base64.
    //
    static byte[] base64Decode(String input) {
        ByteArrayOutputStream output = new ByteArrayOutputStream(input.length() * 3 / 4 + 3);
        int accumulator = 0;
        int bitsCollected = 0;
        for (int index = 0; index < input.length(); index++) {
            char character = input.charAt(index);
            if (character >= 128) {
                continue;
            }
            int value = BASE64_REVERSE[character];
            if (value < 0) {
                continue;
            }
            accumulator = (accumulator << 6) | value;
            bitsCollected += 6;
            if (bitsCollected >= 8) {
                bitsCollected -= 8;
                output.write((accumulator >> bitsCollected) & 0xFF);
            }
        }
        return output.toByteArray();
    }

    //
    // Escapes a string for embedding inside a JSON string literal. Package-private so unit tests can
    // verify the escaping of quotes, backslashes, and control characters.
    //
    static String jsonEscape(String value) {
        StringBuilder builder = new StringBuilder(value.length() + 2);
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"':
                    builder.append("\\\"");
                    break;
                case '\\':
                    builder.append("\\\\");
                    break;
                case '\n':
                    builder.append("\\n");
                    break;
                case '\r':
                    builder.append("\\r");
                    break;
                case '\t':
                    builder.append("\\t");
                    break;
                case '\b':
                    builder.append("\\b");
                    break;
                case '\f':
                    builder.append("\\f");
                    break;
                default:
                    if (character < 0x20) {
                        builder.append(String.format("\\u%04x", (int) character));
                    }
                    else {
                        builder.append(character);
                    }
                    break;
            }
        }
        return builder.toString();
    }
}
