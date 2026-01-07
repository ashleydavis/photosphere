// This file will be loaded to set up the Worker global
// We'll use a simple approach that accesses handlers synchronously

const { getHandler } = require('task-queue/src/lib/worker');
const { TestUuidGenerator, TestTimestampProvider } = require('./node-utils');

class MockWorker {
    constructor(scriptURL) {
        this.scriptURL = scriptURL;
        this.listeners = new Map();
        // Send ready message asynchronously
        process.nextTick(() => {
            this.dispatchMessage({ type: "worker-ready" });
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
            const { taskId, taskType, data } = message;
            // Execute handler synchronously using the already-loaded module
            process.nextTick(async () => {
                try {
                    const handler = getHandler(taskType);
                    if (!handler) {
                        this.dispatchMessage({
                            type: "task-completed",
                            taskId,
                            result: {
                                status: "failed",
                                error: {
                                    name: "Error",
                                    message: `No handler registered for task type: ${taskType}`
                                }
                            }
                        });
                        return;
                    }

                    // Handler signature: (data, context)
                    // Create a proper context similar to what the real worker does
                    const uuidGenerator = new TestUuidGenerator();
                    const timestampProvider = new TestTimestampProvider();
                    const sessionId = uuidGenerator.generate();
                    const context = {
                        uuidGenerator,
                        timestampProvider,
                        sessionId,
                        sendMessage: () => {} // No-op for tests
                    };
                    const outputs = await handler(data, context);
                    this.dispatchMessage({
                        type: "task-completed",
                        taskId,
                        result: {
                            outputs: outputs
                        }
                    });
                }
                catch (error) {
                    // Serialize error similar to how the real worker does it
                    const { serializeError } = require('./serialize-error');
                    const serializedError = serializeError(error);
                    
                    this.dispatchMessage({
                        type: "task-completed",
                        taskId,
                        result: {
                            status: "failed",
                            error: serializedError
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

