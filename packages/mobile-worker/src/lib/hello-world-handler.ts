import { ITaskContext } from "task-queue";

//
// "Hello World" demonstrator background-task handler. A normal task handler (same shape as the
// real handlers): it streams one progress message and returns a greeting. It uses no Node.js
// APIs, so it runs in the embedded engine end to end and proves the background-task round trip
// (WebView -> JsEngine plugin -> pool -> dispatcher -> engine -> runTask -> result) on device.
//
export async function helloWorldHandler(data: any, context: ITaskContext): Promise<any> {
    // Stream a progress message back to the WebView via the host bridge.
    context.sendMessage({ type: "hello-progress", text: "saying hello" });

    const name = data && typeof data.name === "string" ? data.name : "World";
    const platform = globalThis.host ? globalThis.host.platform : "unknown";

    return {
        message: `Hello, ${name}!`,
        platform,
        sessionId: context.sessionId,
    };
}
