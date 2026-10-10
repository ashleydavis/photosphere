package dev.ziggy.shell;

// How an app's own Android code answers the core's host requests: the things only the platform can do (a permission prompt, a keychain,
// a share sheet), each named by a method. The core knows no method names, they are the app's and its handler's. The app gives its handler
// to ZiggyShell.setHostRequestHandler before ZiggyShell.start.
public interface HostRequestHandler {
    // Does what the method names with the JSON text of its argument and returns the JSON text of the answer. It is called on a worker
    // thread of the core, never the main thread, and may block for as long as it takes, for instance to wait for a permission dialog.
    // It throws HostRequestException, with the reason in words the user can act on, for a method it does not know or cannot do.
    String handle(String method, String requestJson) throws HostRequestException;
}
