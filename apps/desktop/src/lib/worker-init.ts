//
// Worker initialization utilities
// Provides context initialization for workers similar to initContext for CLI commands
//

import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { RandomUuidGenerator, TimestampProvider, setLog, ILog } from "utils";
import type { ITaskContext } from "task-queue";
import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Options passed to workers for context initialization
//
export interface IWorkerOptions {
    workerId: number;
    verbose: boolean;
    tools: boolean;
    sessionId: string;
}

// Base worker context (without sendMessage) - used internally in desktop workers
export interface IWorkerContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}


//
// Formats a task ID to show only first 2 and last 2 characters.
// Example: "12345678-1234-1234-1234-123456789abc" -> "12bc"
//
function formatTaskId(taskId: string): string {
    if (taskId.length <= 4) {
        return taskId;
    }
    return `${taskId.substring(0, 2)}${taskId.substring(taskId.length - 2)}`;
}

//
// Simple log implementation for workers (console only, no file logging)
//
class WorkerLog implements ILog {
    readonly verboseEnabled: boolean;
    private readonly toolsEnabled: boolean;
    private readonly workerId: number;
    private currentTaskId: string | null = null;

    constructor(workerId: number, verboseEnabled: boolean, toolsEnabled: boolean) {
        this.workerId = workerId;
        this.verboseEnabled = verboseEnabled;
        this.toolsEnabled = toolsEnabled;
    }

    setTaskId(taskId: string | null): void {
        this.currentTaskId = taskId;
    }

    private prefixMessage(message: string): string {
        const parts: string[] = [`W${this.workerId}`];
        if (this.currentTaskId) {
            parts.push(formatTaskId(this.currentTaskId));
        }
        return `[${parts.join(':')}] ${message}`;
    }

    verbose(message: string): void {    
        if (!this.verboseEnabled) {
            return;
        }
        console.log(this.prefixMessage(message));
    }
    
    info(message: string): void {
        console.log(this.prefixMessage(message));
    }
    
    error(message: string): void {
        console.error(this.prefixMessage(message));
    }
    
    exception(message: string, error: Error): void {
        console.error(this.prefixMessage(message));
        console.error(error.stack || error.message || error);
    }

    warn(message: string): void {
        console.warn(this.prefixMessage(message));
    }

    debug(message: string): void {
        // Workers don't support debug logging
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (!this.toolsEnabled) {
            return;
        }
        
        const parts: string[] = [`W${this.workerId}`];
        if (this.currentTaskId) {
            parts.push(formatTaskId(this.currentTaskId));
        }
        const prefix = `[${parts.join(':')}] `;
        if (data.stdout) {
            console.log(`${prefix}== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            console.log(`${prefix}== ${tool} stderr ==\n${data.stderr}`);
        }
    }
}

// Global reference to the worker log instance for setting task ID
let workerLogInstance: WorkerLog | null = null;

//
// Sets the current task ID for worker logging.
// All subsequent log messages will be prefixed with [shortTaskId].
//
export function setWorkerTaskId(taskId: string | null): void {
    if (workerLogInstance) {
        workerLogInstance.setTaskId(taskId);
    }
}

//
// Initializes worker context (logging, uuid generator, timestamp provider, etc.)
// Similar to initContext but adapted for workers that receive options directly.
//
export function initWorkerContext(options: IWorkerOptions): IWorkerContext {
    // Configure logging (console only for workers)
    const workerLog = new WorkerLog(options.workerId, options.verbose, options.tools);
    workerLogInstance = workerLog;
    setLog(workerLog);
    
    // Test providers are automatically configured when NODE_ENV === "testing"
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
    const timestampProvider = process.env.NODE_ENV === "testing"
        ? new TestTimestampProvider()
        : new TimestampProvider();
    
    return {
        uuidGenerator,
        timestampProvider,
        sessionId: options.sessionId,
    };
}

