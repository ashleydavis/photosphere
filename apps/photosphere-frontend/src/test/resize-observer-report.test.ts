import { isResizeObserverLoopReport } from '../lib/resize-observer-report';

describe("isResizeObserverLoopReport", () => {

    test("is true of WebKit's report of late ResizeObserver notifications, which has no error object", () => {
        expect(isResizeObserverLoopReport("ResizeObserver loop completed with undelivered notifications.", null)).toBe(true);
        expect(isResizeObserverLoopReport("ResizeObserver loop limit exceeded", undefined)).toBe(true);
    });

    test("is false of an exception, even one whose message names ResizeObserver", () => {
        expect(isResizeObserverLoopReport("ResizeObserver loop completed with undelivered notifications.", new Error("thrown"))).toBe(false);
    });

    test("is false of any other uncaught error", () => {
        expect(isResizeObserverLoopReport("TypeError: undefined is not a function", null)).toBe(false);
        expect(isResizeObserverLoopReport("Script error.", undefined)).toBe(false);
    });

    test("is false when the browser gives an event instead of a message", () => {
        expect(isResizeObserverLoopReport(new Event("error"), null)).toBe(false);
    });
});
