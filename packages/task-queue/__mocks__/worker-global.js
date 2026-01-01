// This file will be loaded to set up the Worker global
// We'll use a simple approach that accesses handlers synchronously

const taskWorkerModule = require('../src/lib/worker');

class MockWorker {
    constructor(scriptURL) {
        this.scriptURL = scriptURL;
        this.listeners = new Map();
        // Send ready message asynchronously
        process.nextTick(() => {
            this.dispatchMessage({ type: "ready" });
        });
    }

    addEventListener(type, listener) {
        if (!this.listeners.has(type)) {
            this.listeners.set(type, []);
        }
        this.listeners.get(type).push(listener);
    }

    removeEventListener(type, listener) {
        const listeners = this.listeners.get(type);
        if (listeners) {
            const index = listeners.indexOf(listener);
            if (index > -1) {
                listeners.splice(index, 1);
            }
        }
    }

    postMessage(message) {
        if (message.type === "execute") {
            const { taskId, taskType, data, workingDirectory } = message;
            // Execute handler synchronously using the already-loaded module
            process.nextTick(async () => {
                try {
                    const handler = taskWorkerModule.getHandler(taskType);
                    if (!handler) {
                        this.dispatchMessage({
                            type: "error",
                            taskId,
                            error: {
                                name: "Error",
                                message: `No handler registered for task type: ${taskType}`
                            }
                        });
                        return;
                    }

                    const outputs = await handler(data, workingDirectory);
                    this.dispatchMessage({
                        type: "result",
                        taskId,
                        result: {
                            status: "completed",
                            message: typeof outputs === "string" ? outputs : "Task completed successfully",
                            outputs: outputs
                        }
                    });
                } catch (error) {
                    this.dispatchMessage({
                        type: "error",
                        taskId,
                        error: {
                            name: error?.name || "Error",
                            message: error?.message || String(error),
                            stack: error?.stack
                        }
                    });
                }
            });
        }
    }

    dispatchMessage(data) {
        const listeners = this.listeners.get("message") || [];
        listeners.forEach(listener => {
            listener({ data });
        });
    }

    terminate() {
        this.listeners.clear();
    }
}

global.Worker = MockWorker;

