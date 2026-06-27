import { JsEngine, type IJsEnginePlugin } from "./js-engine-plugin";

//
// Task-related bindings for the mobile platform context. These are the only platform
// callbacks that differ from the no-op mobile stubs: they route through the same native
// JsEngine plugin that EmbeddedJsQueueBackend uses. Kept as standalone functions so they
// can be unit-tested without rendering the React provider.
//

//
// Forwards a cancel-by-source request to the native engine. Used by the Job Manager Cancel
// button via platform.cancelTasks(sourceTag); without this the cancel is a no-op on mobile.
//
export async function cancelMobileTasks(source: string, plugin: IJsEnginePlugin = JsEngine): Promise<void> {
    await plugin.cancelTasks({ source });
}

//
// Subscribes to native taskMessage events, invoking the handler with (taskId, message).
// addListener is async; the returned unsubscribe is synchronous and removes the handle once
// it resolves (or immediately if it has already resolved).
//
export function subscribeMobileTaskMessage(handler: (taskId: string, message: Record<string, unknown>) => void, plugin: IJsEnginePlugin = JsEngine): () => void {
    let removed = false;
    const handlePromise = plugin.addListener("taskMessage", event => {
        handler(event.taskId, event.message as Record<string, unknown>);
    });
    handlePromise.then(handle => {
        if (removed) {
            void handle.remove();
        }
    });
    return () => {
        removed = true;
        void handlePromise.then(handle => handle.remove());
    };
}

//
// Subscribes to native taskCompleted events, invoking the handler with (taskId, result).
// Same async-listener / sync-unsubscribe contract as subscribeMobileTaskMessage.
//
export function subscribeMobileTaskComplete(handler: (taskId: string, result: Record<string, unknown>) => void, plugin: IJsEnginePlugin = JsEngine): () => void {
    let removed = false;
    const handlePromise = plugin.addListener("taskCompleted", event => {
        handler(event.taskId, event.result as unknown as Record<string, unknown>);
    });
    handlePromise.then(handle => {
        if (removed) {
            void handle.remove();
        }
    });
    return () => {
        removed = true;
        void handlePromise.then(handle => handle.remove());
    };
}
