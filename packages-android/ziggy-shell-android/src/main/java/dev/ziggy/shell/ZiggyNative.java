package dev.ziggy.shell;

// The native methods of Ziggy's core. They are implemented in Zig, in the app's core library (see jni.zig in ziggy-core),
// which must be loaded with System.loadLibrary before any of them is called. A handle is the address of what create made.
final class ZiggyNative {
    private ZiggyNative() {
    }

    // Whether the core library was built with the test hooks.
    static native boolean testHooksEnabled();

    // Creates a core and returns its handle. Throws when the core cannot be created. testPortFile may be null.
    static native long create(
        ZiggyHost host,
        int workerThreads,
        int maxConcurrentChildTasks,
        String appUrlPrefix,
        String dataDir,
        boolean testMode,
        String testPortFile);

    // Cancels every running task, waits for the workers to stop and releases the core. Nothing is delivered after it returns.
    static native void destroy(long handle);

    // Delivers a message from the page, as UTF-8 JSON, to the core.
    static native void postMessage(long handle, byte[] message);

    // Decides what to do with an address the web view is about to load: 0 to load it, 1 to open it in the system browser,
    // 2 to block it.
    static native int checkUrl(long handle, byte[] url);
}
