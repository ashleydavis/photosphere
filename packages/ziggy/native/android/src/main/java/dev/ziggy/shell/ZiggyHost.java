package dev.ziggy.shell;

// What the core calls back into. The Zig side (the JNI entry points in Ziggy's core library) holds an object of this type
// and calls these methods, from any thread.
public interface ZiggyHost {
    // A message from the core to the page, as UTF-8 JSON. Called from any thread, and the array belongs to the callee.
    void onCoreMessage(byte[] message);

    // The operating system's version, as the text of a JSON string, such as "Android 16 (API 36)".
    String osVersionJson();

    // Asks the application to quit. Called by the test control connection, from its own thread.
    void quit();

    // Shows a file or folder picker and waits for the user, which blocks the calling thread (a core worker thread, never
    // the main thread). kind is 0 to open files, 1 to save a file (initialName is the suggested name) or 2 to choose a
    // folder. Returns the answer as UTF-8 JSON, an array of path strings that is [] when the user cancelled, or null when
    // the picker could not be shown (the reason has been logged).
    byte[] pickPathsJson(int kind, String title, String initialName);
}
