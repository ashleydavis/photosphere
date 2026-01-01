//TODO: Might want to make a seperate library out of this called task-handler-registry.
//
// Worker infrastructure for task execution
// This module provides the core worker functionality that can be imported
// by application-specific worker files
//

import type { TaskHandler, ITaskContext } from "./types";

const handlers = new Map<string, TaskHandler>();

export function registerHandler(type: string, handler: TaskHandler): void {
    handlers.set(type, handler);
}

export function getHandler(type: string): TaskHandler | undefined {
    return handlers.get(type);
}

export function getRegisteredHandlerTypes(): string[] {
    return Array.from(handlers.keys());
}

//
// Shared function to execute a task handler
// Returns the handler outputs, or throws an error if the handler is not found or execution fails
//
export async function executeTaskHandler(
    taskType: string,
    data: any,
    workingDirectory: string,
    context: ITaskContext
): Promise<any> {
    const registeredTypes = getRegisteredHandlerTypes();
    const handler = getHandler(taskType);
    if (!handler) {
        throw new Error(`No handler registered for task type: ${taskType}. Available handlers: ${registeredTypes.join(", ")}`);
    }

    return await handler(data, workingDirectory, context);
}


