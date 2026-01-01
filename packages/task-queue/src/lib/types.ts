//
// Shared types for task queue system
// These types are used by both the main task queue and worker code
//

import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Task handler function type
// Returns the result payload (can be any type)
//
export type TaskHandler = (data: any, workingDirectory: string, context: IWorkerContext) => Promise<any>;

//
// Worker message interface for communication between main thread and workers
//
export interface WorkerMessage {
    type: "execute";
    taskId: string;
    taskType: string;
    data: any;
    workingDirectory: string;
}

//
// Options passed to workers for context initialization
//
export interface IWorkerOptions {
    verbose?: boolean;
    tools?: boolean;
    sessionId?: string;
}

//
// Common dependencies injected into workers (similar to ICommandContext)
//
export interface IWorkerContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}

