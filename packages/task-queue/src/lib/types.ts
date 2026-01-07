//
// Shared types for task queue system
// These types are used by both the main task queue and worker code
//

import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Task context with all dependencies needed for task execution
//
export interface ITaskContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
    sendMessage: (message: any) => void;
}

//
// Task handler function type
// Returns the result payload (can be any type)
//
export type TaskHandler = (data: any, context: ITaskContext) => Promise<any>;

