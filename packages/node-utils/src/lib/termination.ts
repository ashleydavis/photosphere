import { log } from "utils";

//
// Set to true after the termination handlers have been initialized.
//
let terminationCallbacksInitialized = false;

//
// The type of a callback to handle graceful termination of the process.
//
export type TerminationCallback = () => Promise<void>;

//
// List of registered termination callbacks.
//
const terminationCallbacks: TerminationCallback[] = [];

//
// Invokes all registered termination callbacks.
//
export async function invokeTerminationCallbacks(): Promise<void> {
    for (const callback of terminationCallbacks) {
        await callback();
    }
}

//
// Trigger program termination with a specific exit code.
// Invokes the termination callbacks registered with `registerTerminationCallback`.
//
export async function exit(code: number): Promise<never> {

    try {
        await invokeTerminationCallbacks();
    
        process.exit(code);
    }
    catch (err: any) {
        log.exception('Error during exit termination callbacks.', err);
        process.exit(1);
    }
}

//
// Register a callback function to be called when the process is about to exit.
//
export function registerTerminationCallback(callback: () => Promise<void>): void {
    initializeTerminationHandlers();
    terminationCallbacks.push(callback);
}

//
// Initializes the termination handlers for the process.
//
function initializeTerminationHandlers(): void {
    if (terminationCallbacksInitialized) {
        // Already initialized, no need to do it again.
        return;
    }

    //
    // Listen for the SIGTERM signal (graceful shutdown request)
    //
    process.on('SIGTERM', async () => {
        log.verbose('SIGTERM received. Shutting down gracefully...');

        try {
            await invokeTerminationCallbacks();
            process.exit(0);
        }
        catch (err: any) {
            log.exception('Error during SIGTERM shutdown.', err);
            process.exit(1);
        }
    });

    //
    // Listen for the SIGINT signal (Ctrl+C)
    //
    process.on('SIGINT', async () => {
        log.verbose('SIGINT received. Shutting down...');
        
        try {
            await invokeTerminationCallbacks();
            process.exit(0);
        }
        catch (err: any) {
            log.exception('Error during SIGINT shutdown.', err);
            process.exit(1);
        }
    });

    //
    // Uncaught exceptions
    //
    process.on('uncaughtException', async (err) => {
        log.exception('Uncaught exception.', err);

        try {
            await invokeTerminationCallbacks();
        }
        catch (err: any) {
            log.exception('Error during uncaught exception shutdown.', err);
        }
        finally {
            process.exit(1);
        }
    });

    //
    // Unhandled promise rejections
    //
    process.on('unhandledRejection', async (reason: string, promise) => {
        log.exception('Unhandled promise rejection.', new Error(reason));

        try {
            await invokeTerminationCallbacks();
        }
        catch (err: any) {
            log.exception('Error during unhandled rejection shutdown.', err);
        }
        finally {
            process.exit(1);
        }
    });

    //
    // Before exit (not called on explicit process.exit())
    //
    process.on('beforeExit', (code) => {
        log.verbose(`Process beforeExit with code: ${code}`);
        // Async operations will work here. Exit will not occur while work is scheduled.
    });

    //
    // Exit event (called for all exits)
    //
    process.on('exit', (code) => {
        log.verbose(`Process exiting with code: ${code}`);
        // Only synchronous operations will work here.
    });

    terminationCallbacksInitialized = true;
}
