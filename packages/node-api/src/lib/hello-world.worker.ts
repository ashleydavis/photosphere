import { ITaskContext } from "task-queue";

//
// "Hello World" demonstrator background-task handler for the desktop/CLI worker. Mirrors the
// mobile bundle's handler so the same "Run background task" sidebar action works on every
// platform: it streams one progress message and returns a greeting. Uses no special APIs.
//
export async function helloWorldHandler(data: any, context: ITaskContext): Promise<any> {
    // Stream a progress message back to the client.
    context.sendMessage({ type: "hello-progress", text: "saying hello" });

    const name = data && typeof data.name === "string" ? data.name : "World";

    return {
        message: `Hello, ${name}!`,
        platform: process.platform,
        sessionId: context.sessionId,
    };
}
