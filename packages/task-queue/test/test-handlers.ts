//
// The task handlers the TaskQueue tests register, and the call MockWorkerPool runs a task through.
//

import type { TaskHandler, ITaskContext } from "../src/lib/types";

//
// The handlers the tests have registered, by task type. Module state, so a test registers a handler
// and the mock pool finds it without either being handed the other.
//
const handlers = new Map<string, TaskHandler>();

//
// Registers the handler the mock pool runs for tasks of the given type.
//
export function registerHandler(type: string, handler: TaskHandler): void {
    handlers.set(type, handler);
}

//
// Runs the handler registered for a task type and returns what it returns. Throws, naming the
// types that are registered, when none is registered for that type.
//
export async function executeTaskHandler(
    taskType: string,
    data: any,
    context: ITaskContext
): Promise<any> {
    const handler = handlers.get(taskType);
    if (!handler) {
        throw new Error(`No handler registered for task type: ${taskType}. Available handlers: ${Array.from(handlers.keys()).join(", ")}`);
    }

    return await handler(data, context);
}
