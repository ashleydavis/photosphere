package au.com.codecapers.photosphere.ziggy;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.os.Bundle;
import android.system.ErrnoException;
import android.system.Os;
import android.webkit.WebView;
import dev.ziggy.nativeapp.ZiggyShell;

// Photosphere's one screen: a web view run by Ziggy's shell. What is Photosphere's own is the name of its core library,
// the mobile limits on the core's threads and the process environment the core reads its settings from.
public final class MainActivity extends Activity {
    // The prefix of the Intent extras that become environment variables of the process.
    private static final String ENVIRONMENT_EXTRA_PREFIX = "PHOTOSPHERE_";

    private ZiggyShell shell;

    // The web view the page runs in, kept so the back button can step back through the page's history.
    private WebView webView;

    // Asks the user for permissions on behalf of the core.
    private PermissionRequester permissionRequester;

    // Answers the core's host requests.
    private PhotosphereHostRequests hostRequests;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prepareEnvironment();
        webView = new WebView(this);
        setContentView(webView);
        // Eight worker threads: each of the three background loops (import, sync, prefetch) holds one for as long as it runs, and the
        // page's own requests and the tasks the loops start need the rest.
        shell = new ZiggyShell(this, webView, "photosphere", 8, 2);
        permissionRequester = new PermissionRequester(this);
        hostRequests = new PhotosphereHostRequests(this, permissionRequester);
        ExportHostRequests exportRequests = new ExportHostRequests(this, shell);
        exportRequests.sweep();
        hostRequests.register("exportFile", exportRequests);
        hostRequests.register("exportFiles", exportRequests);
        hostRequests.register("exportTempFolder", exportRequests);
        MediaLibraryHostRequests mediaLibraryRequests = new MediaLibraryHostRequests(this, shell);
        for (String method : new String[] { "mediaLibraryList", "mediaLibraryAlbums", "mediaLibraryOpen", "mediaLibraryClose", "mediaLibraryDelete" }) {
            hostRequests.register(method, mediaLibraryRequests);
        }
        shell.setHostRequestHandler(hostRequests);
        // The wording covers every background loop (import, sync and prefetch), because any one of them can be the reason the service is
        // up and the user switches them on separately.
        shell.setKeepAliveNotification(
            "Automatic photo import",
            "Shown while your photos are being backed up in the background.",
            "Backing up your photos",
            "Photosphere is backing up your photos in the background.");
        shell.start();
    }

    // Puts into the process environment what the core reads its settings from, which it does when the shell creates it, so this
    // runs before the shell starts. A phone passes no environment to an app, so the home directory is the app's files directory
    // (the settings go in the app's private storage, as the sandbox of the Capacitor app held them) and the temporary directory
    // is its cache directory. A debuggable build, which is the only one a test can install, also takes every string extra of the
    // launching Intent whose name starts with PHOTOSPHERE_ as an environment variable of that name, which is how a test starts
    // the app with its settings, vault and logs where it wants them. A build that is not debuggable ignores the extras, because
    // an exported activity can be started by any app and the extras include the choice of vault.
    private void prepareEnvironment() {
        try {
            Os.setenv("HOME", getFilesDir().getAbsolutePath(), true);
            Os.setenv("TMPDIR", getCacheDir().getAbsolutePath(), true);
            if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) {
                return;
            }
            Bundle extras = getIntent().getExtras();
            if (extras == null) {
                return;
            }
            for (String name : extras.keySet()) {
                if (name.startsWith(ENVIRONMENT_EXTRA_PREFIX)) {
                    Os.setenv(name, extras.getString(name), true);
                }
            }
        } catch (ErrnoException error) {
            throw new RuntimeException("Could not set the process environment: " + error.getMessage(), error);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (!shell.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (!permissionRequester.onRequestPermissionsResult(requestCode)) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        }
    }

    // Back steps back through the page's history. With nowhere left to go it sends the app to the background instead of finishing the
    // activity, because finishing destroys the core and so ends the background import, sync and prefetch that the foreground service
    // is keeping alive. Swiping the app away from the recent apps list still ends the process, as it does for any app.
    @Override
    public void onBackPressed() {
        if (webView.canGoBack()) {
            webView.goBack();
            return;
        }
        moveTaskToBack(true);
    }

    @Override
    protected void onResume() {
        super.onResume();
        shell.onResume();
    }

    @Override
    protected void onDestroy() {
        // A worker waiting for a permission prompt is let go first, so destroying the core does not wait for it for ever.
        permissionRequester.cancelPending();
        shell.destroy();
        hostRequests.release();
        super.onDestroy();
    }
}
