//
// Worker initialization utilities
// Provides context initialization for workers similar to initContext for CLI commands
//

import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { RandomUuidGenerator, TimestampProvider, setLog, ILog } from "utils";
import type { IUuidGenerator, ITimestampProvider } from "utils";

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

//
// Simple log implementation for workers (console only, no file logging)
//
class WorkerLog implements ILog {
    readonly verboseEnabled: boolean;
    private readonly toolsEnabled: boolean;

    constructor(verboseEnabled: boolean, toolsEnabled: boolean) {
        this.verboseEnabled = verboseEnabled;
        this.toolsEnabled = toolsEnabled;
    }

    verbose(message: string): void {    
        if (!this.verboseEnabled) {
            return;
        }
        console.log(message);
    }
    
    info(message: string): void {
        console.log(message);
    }
    
    error(message: string): void {
        console.error(message);
    }
    
    exception(message: string, error: Error): void {
        console.error(message);
        console.error(error.stack || error.message || error);
    }

    warn(message: string): void {
        console.warn(message);
    }

    debug(message: string): void {
        // Workers don't support debug logging
    }

    tool(tool: string, data: { stdout?: string; stderr?: string }): void {
        if (!this.toolsEnabled) {
            return;
        }
        
        if (data.stdout) {
            console.log(`== ${tool} stdout ==\n${data.stdout}`);
        }
        if (data.stderr) {
            console.log(`== ${tool} stderr ==\n${data.stderr}`);
        }
    }
}

//
// Initializes worker context (logging, uuid generator, timestamp provider, etc.)
// Similar to initContext but adapted for workers that receive options directly.
//
export function initWorkerContext(options: IWorkerOptions): IWorkerContext {
    // Configure logging (console only for workers)
    const workerLog = new WorkerLog(options.verbose || false, options.tools || false);
    setLog(workerLog);
    
    // Test providers are automatically configured when NODE_ENV === "testing"
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
    const timestampProvider = process.env.NODE_ENV === "testing"
        ? new TestTimestampProvider()
        : new TimestampProvider();
    const sessionId = options.sessionId || uuidGenerator.generate();
    
    return {
        uuidGenerator,
        timestampProvider,
        sessionId,
    };
}

