//
// Whether an uncaught error the page was told about is the browser's report that a ResizeObserver delivered some of its
// notifications a frame late, rather than an exception. WebKit raises it through window.onerror with no error object when an
// observer's callback resizes what it observes, which Joy's Textarea does as it sizes itself to its text, and the late
// notifications are still delivered on the next frame, so nothing failed. The page logged it as an exception, which failed the
// MacOS release workflow's app smoke tests whenever the timing produced one (52-encrypted-database on x64, after opening the add
// secret dialog). An error that carries an error object is a real exception whatever its message says.
//
export function isResizeObserverLoopReport(message: string | Event, error: Error | undefined | null): boolean {
    if (error !== undefined && error !== null) {
        return false;
    }
    if (typeof message !== "string") {
        return false;
    }
    return message.startsWith("ResizeObserver loop");
}
