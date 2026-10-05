package dev.ziggy.shell;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.ClipData;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import org.json.JSONArray;
import org.json.JSONObject;

// Ziggy's Android shell. It configures a WebView, injects window.ziggy before the page's own scripts, loads the app's
// bundled page from the APK assets, calls the core through JNI and moves messages between the page and the core.
//
// An activity creates one, calls start from onCreate and destroy from onDestroy. Messages from the core arrive on any
// thread and are posted to the main thread in order before they touch the web view.
public final class ZiggyShell implements ZiggyHost {
    private static final String TAG = "Ziggy";

    // The Intent extras a test hooks build reads. They are honoured only when the core library has the test hooks.
    private static final String EXTRA_TEST_MODE = "ziggy.testMode";
    private static final String EXTRA_TEST_PORT_FILE = "ziggy.testPortFile";

    // The prefix every address of the app's own page starts with. The page is embedded in the app's native library and each file is
    // answered from there in shouldInterceptRequest. The host name is under .invalid, which can never be looked up.
    private static final String APP_URL_PREFIX = "https://ziggy-app.invalid/";

    // The values of ziggy_check_url's answer.
    private static final int URL_ALLOW = 0;
    private static final int URL_OPEN_EXTERNALLY = 1;

    private final Activity activity;
    private final WebView webView;
    private final String nativeLibraryName;
    private final int workerThreads;
    private final int maxConcurrentChildTasks;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    // Calls into the core hold the read lock and destroy holds the write lock, so the core is never released while a
    // message or an address check is inside it. The page's messages and the web view's request checks come in on threads
    // of their own.
    private final ReentrantReadWriteLock coreLock = new ReentrantReadWriteLock();

    // The core's handle, or 0 before it is created and after it is destroyed. Guarded by coreLock.
    private long handle;

    // Set once the core has been destroyed, so nothing queued for the main thread reaches the web view afterwards.
    private volatile boolean destroyed;

    // The request codes of the three pickers, which are the activity's to tell apart in onActivityResult. They are the
    // pick kinds added to this base.
    private static final int PICK_REQUEST_CODE_BASE = 0x5A00;

    // Held while a picker is on screen, so only one is shown at a time. The system shows one document picker at a time anyway.
    private final Object pickMutex = new Object();

    // Where the waiting core thread receives the picker's result, or null when no picker is on screen.
    private volatile BlockingQueue<Intent> pendingPick;

    // The request code of the picker on screen.
    private volatile int pendingPickRequestCode;

    // What a picker answers when it is dismissed with no choice, or the shell is being destroyed under it.
    private static final Intent NOTHING_PICKED = new Intent();

    public ZiggyShell(Activity activity, WebView webView, String nativeLibraryName, int workerThreads, int maxConcurrentChildTasks) {
        this.activity = activity;
        this.webView = webView;
        this.nativeLibraryName = nativeLibraryName;
        this.workerThreads = workerThreads;
        this.maxConcurrentChildTasks = maxConcurrentChildTasks;
    }

    // Creates the core, configures the web view and loads the page. Call it once, on the main thread.
    public void start() {
        System.loadLibrary(nativeLibraryName);
        Intent intent = activity.getIntent();
        boolean testMode = ZiggyNative.testHooksEnabled() && intent.getBooleanExtra(EXTRA_TEST_MODE, false);
        String testPortFile = null;
        if (testMode) {
            testPortFile = intent.getStringExtra(EXTRA_TEST_PORT_FILE);
        }

        long created = ZiggyNative.create(
            this,
            workerThreads,
            maxConcurrentChildTasks,
            APP_URL_PREFIX,
            activity.getFilesDir().getAbsolutePath(),
            testMode,
            testPortFile);
        coreLock.writeLock().lock();
        try {
            handle = created;
        } finally {
            coreLock.writeLock().unlock();
        }

        configureWebView();
        webView.loadUrl(APP_URL_PREFIX + "index.html" + (testMode ? "?testMode=1" : ""));
    }

    // Destroys the core once. After it returns nothing more is delivered to the page. Call it from onDestroy.
    public void destroy() {
        destroyed = true;
        // Destroying the core waits for its worker threads, and one may be waiting on a picker that will now never answer.
        BlockingQueue<Intent> waiting = pendingPick;
        if (waiting != null) {
            waiting.offer(NOTHING_PICKED);
        }
        coreLock.writeLock().lock();
        try {
            if (handle == 0) {
                return;
            }
            long destroying = handle;
            handle = 0;
            ZiggyNative.destroy(destroying);
        } finally {
            coreLock.writeLock().unlock();
        }
        webView.destroy();
    }

    private void configureWebView() {
        // The page is a classic script bundle served from the APK assets. File access is off, because the assets load
        // without it, and nothing else on the file system is the page's to read.
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setAllowContentAccess(false);
        settings.setGeolocationEnabled(false);
        settings.setSupportMultipleWindows(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        if ((activity.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true);
        }

        // The script has to run before the page's own scripts, and only the document start API guarantees that: running it
        // when the page starts loading races the page's first script. So a web view without the API is refused here, loudly,
        // and there is no fallback that could quietly lose the race.
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            throw new IllegalStateException("This WebView cannot run a script at document start (WebViewFeature.DOCUMENT_START_SCRIPT), which Ziggy needs to expose window.ziggy before the page's scripts.");
        }
        WebViewCompat.addDocumentStartJavaScript(webView, new String(ZiggyNative.injectScript(), StandardCharsets.UTF_8), Collections.singleton("*"));

        webView.addJavascriptInterface(new PageBridge(), "ZiggyAndroid");
        webView.setWebViewClient(new ZiggyWebViewClient());
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage message) {
                Log.println(
                    message.messageLevel() == ConsoleMessage.MessageLevel.ERROR ? Log.ERROR : Log.INFO,
                    TAG,
                    "page console: " + message.message() + " (" + message.sourceId() + ":" + message.lineNumber() + ")");
                return true;
            }
        });
    }

    // Answers a request to the app's own page from the files embedded in the core library: the file's bytes with its content
    // type, or a 404 when the page has no such file. Anything asked after the core is destroyed is refused.
    private WebResourceResponse pageResponse(String url) {
        String path = url.substring(APP_URL_PREFIX.length());
        int pathEnd = path.length();
        for (int index = 0; index < path.length(); index++) {
            char character = path.charAt(index);
            if (character == '?' || character == '#') {
                pathEnd = index;
                break;
            }
        }
        byte[] pathBytes = path.substring(0, pathEnd).getBytes(StandardCharsets.UTF_8);
        byte[] content;
        String contentType;
        coreLock.readLock().lock();
        try {
            if (handle == 0) {
                return new WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", Collections.<String, String>emptyMap(), new ByteArrayInputStream(new byte[0]));
            }
            content = ZiggyNative.uiFileContent(handle, pathBytes);
            contentType = ZiggyNative.uiFileContentType(handle, pathBytes);
        } finally {
            coreLock.readLock().unlock();
        }
        if (content == null || contentType == null) {
            return new WebResourceResponse("text/plain", "UTF-8", 404, "Not Found", Collections.<String, String>emptyMap(), new ByteArrayInputStream(new byte[0]));
        }
        // The content type is such as "text/javascript; charset=utf-8": the web view wants the type and the character set apart.
        String mimeType = contentType;
        String encoding = null;
        int separator = contentType.indexOf(';');
        if (separator >= 0) {
            mimeType = contentType.substring(0, separator).trim();
            encoding = "UTF-8";
        }
        return new WebResourceResponse(mimeType, encoding, 200, "OK", Collections.<String, String>emptyMap(), new ByteArrayInputStream(content));
    }

    // Asks the core what to do with an address. Anything asked after the core is destroyed is refused.
    private int checkUrl(String url) {
        coreLock.readLock().lock();
        try {
            if (handle == 0) {
                return 2;
            }
            return ZiggyNative.checkUrl(handle, url.getBytes(StandardCharsets.UTF_8));
        } finally {
            coreLock.readLock().unlock();
        }
    }

    @Override
    public void onCoreMessage(byte[] message) {
        final String text = new String(message, StandardCharsets.UTF_8);
        mainHandler.post(new Runnable() {
            @Override
            public void run() {
                if (destroyed) {
                    return;
                }
                webView.evaluateJavascript("window.__ziggyReceive(" + text + ");", null);
            }
        });
    }

    @Override
    public String osVersionJson() {
        return JSONObject.quote("Android " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ") " + Build.MANUFACTURER + " " + Build.MODEL);
    }

    @Override
    public void quit() {
        activity.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                // A picker on screen would keep this activity alive until the user closed it, so it is closed first.
                if (pendingPick != null) {
                    activity.finishActivity(pendingPickRequestCode);
                }
                activity.finish();
            }
        });
    }

    // Feeds a picker's result to the core thread waiting for it. The activity calls this from onActivityResult. Returns whether
    // the result was a picker's.
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        BlockingQueue<Intent> waiting = pendingPick;
        if (waiting == null || requestCode != pendingPickRequestCode) {
            return false;
        }
        waiting.offer(resultCode == Activity.RESULT_OK && data != null ? data : NOTHING_PICKED);
        return true;
    }

    @Override
    public byte[] pickPathsJson(int kind, String title, String initialName) {
        // The system's document pickers have no title of their own to set (EXTRA_TITLE on a save is the file name), so the
        // title is not shown.
        synchronized (pickMutex) {
            final int requestCode = PICK_REQUEST_CODE_BASE + kind;
            final BlockingQueue<Intent> answer = new ArrayBlockingQueue<Intent>(1);
            pendingPickRequestCode = requestCode;
            pendingPick = answer;
            try {
                if (destroyed) {
                    return "[]".getBytes(StandardCharsets.UTF_8);
                }
                final Intent request = pickIntent(kind, initialName);
                activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            activity.startActivityForResult(request, requestCode);
                        } catch (ActivityNotFoundException error) {
                            Log.e(TAG, "Nothing on this device can show the picker", error);
                            answer.offer(NOTHING_PICKED);
                        }
                    }
                });
                Intent result = answer.take();
                return resultToJson(kind, result).getBytes(StandardCharsets.UTF_8);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                Log.e(TAG, "Interrupted while waiting for the picker", error);
                return null;
            } catch (IOException | RuntimeException error) {
                Log.e(TAG, "The picker's answer could not be read", error);
                return null;
            } finally {
                pendingPick = null;
            }
        }
    }

    private Intent pickIntent(int kind, String initialName) {
        Intent intent;
        switch (kind) {
            case 0:
                intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                return intent;
            case 1:
                intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("application/octet-stream");
                if (initialName != null && !initialName.isEmpty()) {
                    intent.putExtra(Intent.EXTRA_TITLE, initialName);
                }
                return intent;
            case 2:
                return new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            default:
                throw new IllegalArgumentException("Unknown picker kind " + kind);
        }
    }

    // Turns a picker's result into the JSON array the core expects. Chosen documents to open are copied into the app's cache
    // directory and answered as file system paths. A folder or a save location is answered as the Uri string, which is not a
    // file system path.
    private String resultToJson(int kind, Intent result) throws IOException {
        JSONArray paths = new JSONArray();
        if (result == NOTHING_PICKED) {
            return paths.toString();
        }
        if (kind != 0) {
            Uri uri = result.getData();
            if (uri == null) {
                throw new IOException("The picker answered with no address");
            }
            paths.put(uri.toString());
            return paths.toString();
        }
        ClipData clip = result.getClipData();
        if (clip != null) {
            for (int index = 0; index < clip.getItemCount(); index++) {
                paths.put(copyToCache(clip.getItemAt(index).getUri()));
            }
        } else if (result.getData() != null) {
            paths.put(copyToCache(result.getData()));
        } else {
            throw new IOException("The picker answered with no documents");
        }
        return paths.toString();
    }

    // Copies a chosen document into a directory of its own under the cache directory, named as the document is, and returns the
    // file's path.
    private String copyToCache(Uri uri) throws IOException {
        String name = "document";
        try (Cursor cursor = activity.getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                name = cursor.getString(0).replace('/', '_').replace('\0', '_');
            }
        }
        if (name.isEmpty() || name.equals(".") || name.equals("..")) {
            name = "document";
        }
        File directory = new File(activity.getCacheDir(), "ziggy-picked/" + UUID.randomUUID());
        if (!directory.mkdirs()) {
            throw new IOException("Could not create " + directory);
        }
        File file = new File(directory, name);
        try (InputStream input = activity.getContentResolver().openInputStream(uri);
             OutputStream output = new FileOutputStream(file)) {
            if (input == null) {
                throw new IOException("No content provider answered for " + uri);
            }
            byte[] buffer = new byte[65536];
            int count;
            while ((count = input.read(buffer)) != -1) {
                output.write(buffer, 0, count);
            }
        }
        return file.getAbsolutePath();
    }

    // The object the page reaches as window.ZiggyAndroid. Its one method is how the injected script posts a message.
    private final class PageBridge {
        @JavascriptInterface
        public void postMessage(String message) {
            coreLock.readLock().lock();
            try {
                if (handle == 0) {
                    Log.w(TAG, "A message from the page arrived after the core was destroyed and was dropped");
                    return;
                }
                ZiggyNative.postMessage(handle, message.getBytes(StandardCharsets.UTF_8));
            } finally {
                coreLock.readLock().unlock();
            }
        }
    }

    // Decides every navigation and request with the core's origin check: the app's own page loads, http, https and mailto
    // links open in the system browser, and everything else is blocked.
    private final class ZiggyWebViewClient extends WebViewClient {
        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            String url = request.getUrl().toString();
            int verdict = checkUrl(url);
            if (verdict == URL_ALLOW) {
                return false;
            }
            if (verdict == URL_OPEN_EXTERNALLY) {
                try {
                    activity.startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
                } catch (ActivityNotFoundException error) {
                    Log.e(TAG, "Nothing on this device can open " + url, error);
                }
            } else {
                Log.w(TAG, "Blocked a navigation to " + url);
            }
            return true;
        }

        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            String url = request.getUrl().toString();
            if (url.startsWith(APP_URL_PREFIX)) {
                return pageResponse(url);
            }
            if (checkUrl(url) == URL_ALLOW) {
                return null;
            }
            Log.w(TAG, "Blocked a request to " + url);
            return new WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", Collections.<String, String>emptyMap(), new ByteArrayInputStream(new byte[0]));
        }

        @Override
        public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            Log.e(TAG, "The web view's render process is gone (crashed: " + detail.didCrash() + "). Ending the app.");
            activity.finish();
            return true;
        }
    }
}
