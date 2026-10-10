package au.com.codecapers.photosphere.ziggy;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.provider.DocumentsContract;
import dev.ziggy.shell.HostRequestException;
import dev.ziggy.shell.HostRequestHandler;
import dev.ziggy.shell.ZiggyShell;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

// Hands finished files out of the app: exportFile asks the user where to save one file, exportFiles asks which folder to put several
// in. The download has already written the bytes under the app's files directory at the sandbox-relative paths in the request. Every
// exit, whether the files were saved, the user backed out or the copy failed, removes the temporary copies. The core calls from a
// worker thread and waits, so a request may block on the system's picker.
public final class ExportHostRequests implements HostRequestHandler {
    private final Context context;
    private final ZiggyShell shell;
    private final File storageRoot;

    public ExportHostRequests(Context context, ZiggyShell shell) {
        this.context = context;
        this.shell = shell;
        this.storageRoot = context.getFilesDir();
    }

    // Removes the export temp directory, collecting any copies left by the app being killed while a picker was on screen.
    public void sweep() {
        ExportTemp.sweep(storageRoot);
    }

    @Override
    public String handle(String method, String requestJson) throws HostRequestException {
        try {
            JSONObject request = new JSONObject(requestJson);
            if (method.equals("exportFile")) {
                return exportFile(request.getString("path"), request.optString("testOutcome", null));
            }
            if (method.equals("exportTempFolder")) {
                return exportTempFolder(request.getString("folder"));
            }
            if (method.equals("exportFiles")) {
                return exportFiles(readPaths(request.getJSONArray("paths")), request.optString("testOutcome", null));
            }
        } catch (JSONException error) {
            throw new HostRequestException("The request " + method + " was not understood: " + error.getMessage(), error);
        }
        throw new HostRequestException("ExportHostRequests does not answer \"" + method + "\".");
    }

    // Makes the folder one export's files are written into, so the save task can create files in it, and says where it is.
    private String exportTempFolder(String folder) throws HostRequestException, JSONException {
        try {
            File made = ExportTemp.prepareFolder(storageRoot, folder);
            return new JSONObject().put("path", made.getAbsolutePath()).toString();
        } catch (SecurityException error) {
            throw new HostRequestException("exportTempFolder: " + error.getMessage(), error);
        } catch (IOException error) {
            throw new HostRequestException("exportTempFolder: " + error.getMessage(), error);
        }
    }

    // Lets the user choose a destination for one file, copies it there and removes the temporary copy.
    // A request carrying a test outcome skips the picker and goes straight to the completion path, because the picker cannot be
    // answered by an automated test.
    private String exportFile(String path, String testOutcome) throws HostRequestException, JSONException {
        File temp = resolve(path, "exportFile");
        try {
            if (testOutcome != null) {
                String exported = ExportTemp.finishExport(storageRoot, path, ExportTemp.isCancelledTestOutcome(testOutcome));
                return new JSONObject().put("path", exported == null ? JSONObject.NULL : exported).toString();
            }
            Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*");
            intent.putExtra(Intent.EXTRA_TITLE, temp.getName());
            Intent result = start(intent, "exportFile");
            boolean cancelled = result == null || result.getData() == null;
            if (!cancelled) {
                copyTempToDestination(path, result.getData());
            }
            String exported = ExportTemp.finishExport(storageRoot, path, cancelled);
            return new JSONObject().put("path", exported == null ? JSONObject.NULL : exported).toString();
        } catch (IOException error) {
            throw new HostRequestException("exportFile: failed to write destination: " + error.getMessage(), error);
        } finally {
            ExportTemp.deleteTemp(storageRoot, path);
        }
    }

    // Lets the user choose a folder, copies every file into it and removes the temporary copies.
    // A request carrying a test outcome skips the picker, as for exportFile.
    private String exportFiles(List<String> paths, String testOutcome) throws HostRequestException, JSONException {
        try {
            for (String path : paths) {
                resolve(path, "exportFiles");
            }
            boolean cancelled;
            if (testOutcome != null) {
                cancelled = ExportTemp.isCancelledTestOutcome(testOutcome);
            } else {
                Intent result = start(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), "exportFiles");
                cancelled = result == null || result.getData() == null;
                if (!cancelled) {
                    copyTempsIntoTree(paths, result.getData());
                }
            }
            List<String> exported = ExportTemp.finishExportBatch(storageRoot, paths, cancelled);
            JSONObject reply = new JSONObject();
            if (exported == null) {
                reply.put("paths", JSONObject.NULL);
            } else {
                reply.put("paths", new JSONArray(exported));
            }
            return reply.toString();
        } catch (IOException error) {
            throw new HostRequestException("exportFiles: failed to write destination: " + error.getMessage(), error);
        } finally {
            for (String path : paths) {
                ExportTemp.deleteTemp(storageRoot, path);
            }
        }
    }

    // Confirms a temporary file is inside the sandbox before anything is shown.
    private File resolve(String path, String method) throws HostRequestException {
        try {
            return PathSandbox.resolveWithin(storageRoot, path);
        } catch (SecurityException error) {
            throw new HostRequestException(method + ": " + error.getMessage(), error);
        }
    }

    // Shows the system's picker and waits. Null means the user backed out.
    private Intent start(Intent intent, String method) throws HostRequestException {
        try {
            return shell.startActivityAndWait(intent);
        } catch (ActivityNotFoundException error) {
            throw new HostRequestException(method + ": nothing on this device can show the save picker.", error);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new HostRequestException(method + ": the save picker was interrupted.", interrupted);
        }
    }

    private void copyTempToDestination(String relativePath, Uri destination) throws IOException {
        File source = PathSandbox.resolveWithin(storageRoot, relativePath);
        try (InputStream input = new FileInputStream(source);
             OutputStream output = context.getContentResolver().openOutputStream(destination)) {
            if (output == null) {
                throw new IOException("could not open destination stream");
            }
            ExportTemp.copyStream(input, output);
        }
    }

    // Copies each file into the chosen document tree as a new document, keeping each file's own name.
    private void copyTempsIntoTree(List<String> relativePaths, Uri treeUri) throws IOException {
        Uri documentTreeUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri));
        for (String relativePath : relativePaths) {
            File source = PathSandbox.resolveWithin(storageRoot, relativePath);
            Uri created = DocumentsContract.createDocument(context.getContentResolver(), documentTreeUri, "application/octet-stream", source.getName());
            if (created == null) {
                throw new IOException("could not create destination document for " + source.getName());
            }
            copyTempToDestination(relativePath, created);
        }
    }

    private static List<String> readPaths(JSONArray array) throws JSONException {
        List<String> paths = new ArrayList<String>();
        for (int index = 0; index < array.length(); index++) {
            paths.add(array.getString(index));
        }
        return paths;
    }
}
