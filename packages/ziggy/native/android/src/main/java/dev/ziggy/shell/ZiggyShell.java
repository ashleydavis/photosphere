package dev.ziggy.shell;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.IntentSender;
import android.content.pm.ApplicationInfo;
import android.content.ClipData;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.graphics.Insets;
import android.util.Log;
import android.view.ViewGroup;
import android.view.WindowInsets;
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
import java.util.ArrayList;
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

    // True once the page has finished loading, so window.__ziggyReceive exists. Only the main thread reads or writes it.
    private boolean pageReady;

    // The messages the core sent before the page finished loading, held for the main thread to deliver when it has.
    private final ArrayList<String> beforePage = new ArrayList<String>();

    // Set once the core has been destroyed, so nothing queued for the main thread reaches the web view afterwards.
    private volatile boolean destroyed;

    // Guards the keep-alive state below.
    private final Object keepAliveMutex = new Object();

    // Whether the core last asked for the app to be kept running.
    private boolean keepAliveWanted;

    // Whether the system refused the last start of the keep-alive service, so the shell asks again when the activity resumes.
    private boolean keepAliveRefused;

    // Answers the core's host requests, or null when the app gave none.
    private volatile HostRequestHandler hostRequestHandler;

    // The request codes of the three pickers, which are the activity's to tell apart in onActivityResult. They are the
    // pick kinds added to this base.
    private static final int PICK_REQUEST_CODE_BASE = 0x5A00;

    // The request code of an activity started by startActivityAndWait.
    private static final int ACTIVITY_REQUEST_CODE = 0x5A80;

    // Held while a picker is on screen, so only one is shown at a time. The system shows one document picker at a time anyway.
    private final Object pickMutex = new Object();

    // Where the waiting core thread receives the picker's result, or null when no picker is on screen.
    private volatile BlockingQueue<Intent> pendingPick;

    // The request code of the picker on screen.
    private volatile int pendingPickRequestCode;

    // Whether the activity that last answered finished with RESULT_OK, which an activity that returns no data (a system confirmation)
    // answers with. Written by onActivityResult before it releases the waiting thread.
    private volatile boolean lastActivityResultOk;

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
        String query = new String(ZiggyNative.pageQuery(created), StandardCharsets.UTF_8);
        webView.loadUrl(APP_URL_PREFIX + "index.html" + (query.isEmpty() ? "" : "?" + query));
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
        // localStorage and IndexedDB are off in a web view until this is set, and a page expects them to work.
        settings.setDomStorageEnabled(true);
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

        // An app targeting Android 15 or later is drawn edge to edge, with the web view running under the status bar, the
        // navigation bar and the keyboard. The page is shared with platforms that have no such bars, so the shell keeps the web
        // view's content clear of them by giving it margins of the insets the window reports, which also keeps working once the
        // platform stops letting an app opt out of edge to edge.
        // Before Android 11 the window insets have no per-bar types, and before Android 15 the system keeps an app inside the
        // bars by itself, so there is nothing to do there.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            webView.setOnApplyWindowInsetsListener((view, insets) -> {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
                // Margins, not padding: a web view lays its page out over its padding.
                ViewGroup.MarginLayoutParams layout = (ViewGroup.MarginLayoutParams) view.getLayoutParams();
                layout.setMargins(bars.left, bars.top, bars.right, bars.bottom);
                view.setLayoutParams(layout);
                return WindowInsets.CONSUMED;
            });
        }

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
                if (!pageReady) {
                    beforePage.add(text);
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


    // What the keep-alive service's notification says, as the app supplied it. Null until the app calls setKeepAliveNotification, in
    // which case the service uses wording of its own.
    private String[] keepAliveNotificationText;

    // Sets what the keep-alive service's ongoing notification says, which is the app's to word because only it knows what its background
    // work is. Call it before start. The channel name and description are what the system settings show for the notification.
    public void setKeepAliveNotification(String channelName, String channelDescription, String title, String text) {
        keepAliveNotificationText = new String[] { channelName, channelDescription, title, text };
    }

    // The intent that starts or stops the keep-alive service, carrying the wording the app supplied.
    private Intent keepAliveIntent() {
        Intent intent = new Intent(activity, ZiggyKeepAliveService.class);
        if (keepAliveNotificationText != null) {
            intent.putExtra(ZiggyKeepAliveService.EXTRA_CHANNEL_NAME, keepAliveNotificationText[0]);
            intent.putExtra(ZiggyKeepAliveService.EXTRA_CHANNEL_DESCRIPTION, keepAliveNotificationText[1]);
            intent.putExtra(ZiggyKeepAliveService.EXTRA_TITLE, keepAliveNotificationText[2]);
            intent.putExtra(ZiggyKeepAliveService.EXTRA_TEXT, keepAliveNotificationText[3]);
        }
        return intent;
    }
    // Starts or stops the foreground service that keeps the process running while the core has tasks the app must be kept running
    // for. Starting happens when the task is queued, which is while the app is in the foreground, as Android requires. From Android 12
    // an app that is not in the foreground yet is refused, and it can be refused as the app launches, before the system counts it as
    // foreground. The refusal is logged, and the start is asked for again when the activity resumes (see onResume).
    @Override
    public void keepAlive(boolean keepRunning) {
        synchronized (keepAliveMutex) {
            boolean neverStarted = keepAliveRefused;
            keepAliveWanted = keepRunning;
            keepAliveRefused = false;
            Intent intent = keepAliveIntent();
            if (!keepRunning) {
                if (neverStarted) {
                    return;
                }
                // The service is asked to end itself rather than stopped from here, because a stop that reaches it before it has
                // answered its own start with startForeground crashes the app, and a task that ends at once makes that race likely.
                // When the system refuses the request (the app is in the background), no start is waiting for an answer, so the
                // service is stopped directly.
                intent.putExtra(ZiggyKeepAliveService.EXTRA_STOP, true);
                try {
                    activity.startForegroundService(intent);
                } catch (RuntimeException refused) {
                    activity.stopService(intent);
                }
                return;
            }
            try {
                activity.startForegroundService(intent);
            } catch (RuntimeException refused) {
                keepAliveRefused = true;
                Log.w(TAG, "The system refused to start the keep-alive service, which happens when the app is not in the foreground yet. It is asked for again when the app resumes.", refused);
            }
        }
    }

    // Tells the shell the activity has resumed, which is a moment the system allows a foreground service to start. If the system
    // refused the keep-alive service earlier, and the core still wants it, it is started now. The activity calls this from onResume.
    public void onResume() {
        synchronized (keepAliveMutex) {
            if (!keepAliveWanted || !keepAliveRefused) {
                return;
            }
            Log.i(TAG, "Asking for the keep-alive service again now the app is resumed.");
            keepAliveRefused = false;
            try {
                activity.startForegroundService(keepAliveIntent());
            } catch (RuntimeException refused) {
                keepAliveRefused = true;
                Log.w(TAG, "The system refused to start the keep-alive service even though the app has resumed.", refused);
            }
        }
    }

    // Gives the shell the object that answers the core's host requests. Call it before start. Without one, every host request is
    // answered as a failure that says so.
    public void setHostRequestHandler(HostRequestHandler handler) {
        hostRequestHandler = handler;
    }

    @Override
    public byte[] hostRequest(byte[] method, byte[] requestJson) {
        String methodName = new String(method, StandardCharsets.UTF_8);
        HostRequestHandler handler = hostRequestHandler;
        if (handler == null) {
            return HostRequestAnswer.failed("This app's Android shell has no handler for the request " + methodName + ".");
        }
        try {
            return HostRequestAnswer.succeeded(handler.handle(methodName, new String(requestJson, StandardCharsets.UTF_8)));
        } catch (HostRequestException failure) {
            Log.w(TAG, "The host request " + methodName + " failed: " + failure.getMessage(), failure);
            return HostRequestAnswer.failed(failure.getMessage());
        } catch (RuntimeException error) {
            Log.e(TAG, "The host request " + methodName + " threw", error);
            return HostRequestAnswer.failed("The host request " + methodName + " failed: " + error);
        }
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
        lastActivityResultOk = resultCode == Activity.RESULT_OK;
        waiting.offer(resultCode == Activity.RESULT_OK && data != null ? data : NOTHING_PICKED);
        return true;
    }

    // Starts an activity for the app's own host request handlers and waits for it to finish, from a thread that is not the main
    // thread. Returns the activity's result data, or null when the user backed out, the activity gave no data or the shell is being
    // destroyed. It shares the one slot the pickers use, so only one such activity is on screen at a time.
    public Intent startActivityAndWait(final Intent request) throws InterruptedException, ActivityNotFoundException {
        synchronized (pickMutex) {
            final int requestCode = ACTIVITY_REQUEST_CODE;
            final BlockingQueue<Intent> answer = new ArrayBlockingQueue<Intent>(1);
            final ActivityNotFoundException[] notFound = new ActivityNotFoundException[1];
            pendingPickRequestCode = requestCode;
            pendingPick = answer;
            try {
                if (destroyed) {
                    return null;
                }
                activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            activity.startActivityForResult(request, requestCode);
                        } catch (ActivityNotFoundException error) {
                            notFound[0] = error;
                            answer.offer(NOTHING_PICKED);
                        }
                    }
                });
                Intent result = answer.take();
                if (notFound[0] != null) {
                    throw notFound[0];
                }
                return result == NOTHING_PICKED ? null : result;
            } finally {
                pendingPick = null;
            }
        }
    }

    // Starts a system confirmation given as an IntentSender (a PendingIntent's) and waits for the user to answer it, from a thread that
    // is not the main thread. Returns whether the user accepted it (RESULT_OK), and false when they declined, the confirmation could
    // not be shown or the shell is being destroyed. It shares the one slot the pickers use.
    public boolean startIntentSenderAndWait(final IntentSender sender) throws InterruptedException {
        synchronized (pickMutex) {
            final int requestCode = ACTIVITY_REQUEST_CODE;
            final BlockingQueue<Intent> answer = new ArrayBlockingQueue<Intent>(1);
            final IntentSender.SendIntentException[] failure = new IntentSender.SendIntentException[1];
            pendingPickRequestCode = requestCode;
            pendingPick = answer;
            lastActivityResultOk = false;
            try {
                if (destroyed) {
                    return false;
                }
                activity.runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            activity.startIntentSenderForResult(sender, requestCode, null, 0, 0, 0);
                        } catch (IntentSender.SendIntentException error) {
                            failure[0] = error;
                            answer.offer(NOTHING_PICKED);
                        }
                    }
                });
                answer.take();
                if (failure[0] != null) {
                    Log.e(TAG, "Could not present the confirmation", failure[0]);
                    return false;
                }
                return lastActivityResultOk;
            } finally {
                pendingPick = null;
            }
        }
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
        public void onPageStarted(WebView view, String url, Bitmap favicon) {
            pageReady = false;
        }

        // The injected script ran at document start, so window.__ziggyReceive exists now: the messages the core sent while the
        // page was loading are delivered in the order they were sent.
        @Override
        public void onPageFinished(WebView view, String url) {
            pageReady = true;
            for (String text : beforePage) {
                webView.evaluateJavascript("window.__ziggyReceive(" + text + ");", null);
            }
            beforePage.clear();
        }

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
            // Only a navigation is checked, as on every other platform. The page loads media from a server on the loopback address.
            if (!request.isForMainFrame() || checkUrl(url) == URL_ALLOW) {
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
