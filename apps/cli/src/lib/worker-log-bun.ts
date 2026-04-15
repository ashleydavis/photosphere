//
// Worker log implementation for Bun CLI workers.
// Writes log messages directly to the console, prefixed with worker and task IDs.
//

import { ILog, formatErrorChain } from "utils";

//
// Bun CLI worker log implementation.
// Writes log messages directly to the console, prefixed with worker and task IDs.
//
class WorkerLogBun implements ILog {
    // Whether verbose logging is enabled.
    readonly verboseEnabled: boolean;

    // Whether tool output logging is enabled.
    private readonly toolsEnabled: boolean;

    // Numeric ID of this worker, used in log prefixes.
    private readonly workerId: number;

    // The current task ID for log prefixing, null when idle.
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
            parts.push(this.currentTaskId);
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
        console.error(formatErrorChain(error));
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
        
        if (data.stdout) {
            console.log(this.prefixMessage(`== ${tool} stdout ==\n${data.stdout}`));
        }
        if (data.stderr) {
            console.log(this.prefixMessage(`== ${tool} stderr ==\n${data.stderr}`));
        }
    }
}

// Global reference to the worker log instance for setting task ID
let workerLogInstance: WorkerLogBun | null = null;

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
// Creates and registers a WorkerLogBun instance for the given worker.
// Call setLog() with the returned value to activate it.
//
export function createWorkerLog(workerId: number, verbose: boolean, tools: boolean): ILog {
    const workerLog = new WorkerLogBun(workerId, verbose, tools);
    workerLogInstance = workerLog;
    return workerLog;
}

