import { log } from "utils";
import {
    EXIT_FAILURE,
    EXIT_SUCCESS,
    EXIT_TERMINATION_CALLBACKS_THREW,
    EXIT_SIGTERM_CLEANUP_FAILED,
    EXIT_SIGINT_CLEANUP_FAILED,
    EXIT_UNCAUGHT_EXCEPTION,
    EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED,
    EXIT_UNHANDLED_REJECTION,
    EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED,
} from "./exit-codes";

//
// Set to true after the termination handlers have been initialized.
//
let terminationCallbacksInitialized = false;

//
// The type of a callback to handle graceful termination of the process.
// The exit code is passed to indicate whether the process is exiting successfully (0) or with an error (non-zero).
//
export type TerminationCallback = (exitCode: number) => Promise<void>;

//
// List of registered termination callbacks.
//
const terminationCallbacks: TerminationCallback[] = [];

//
// Invokes all registered termination callbacks with the given exit code.
//
export async function invokeTerminationCallbacks(exitCode: number): Promise<void> {
    for (const callback of terminationCallbacks) {
        await callback(exitCode);
    }
}

//
// Trigger program termination with a specific exit code.
// Invokes the termination callbacks registered with `registerTerminationCallback`.
//
export async function exit(code: number): Promise<never> {

    try {
        await invokeTerminationCallbacks(code);
    
        process.exit(code);
    }
    catch (err: any) {
        log.exception('Error during exit termination callbacks.', err);
        process.exit(EXIT_TERMINATION_CALLBACKS_THREW);
    }
}

//
// Register a callback function to be called when the process is about to exit.
//
export function registerTerminationCallback(callback: TerminationCallback): void {
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
            await invokeTerminationCallbacks(EXIT_SUCCESS);
            process.exit(EXIT_SUCCESS);
        }
        catch (err: any) {
            log.exception('Error during SIGTERM shutdown.', err);
            await invokeTerminationCallbacks(EXIT_FAILURE);
            process.exit(EXIT_SIGTERM_CLEANUP_FAILED);
        }
    });

    //
    // Listen for the SIGINT signal (Ctrl+C)
    //
    process.on('SIGINT', async () => {
        log.verbose('SIGINT received. Shutting down...');

        try {
            await invokeTerminationCallbacks(EXIT_SUCCESS);
            process.exit(EXIT_SUCCESS);
        }
        catch (err: any) {
            log.exception('Error during SIGINT shutdown.', err);
            await invokeTerminationCallbacks(EXIT_FAILURE);
            process.exit(EXIT_SIGINT_CLEANUP_FAILED);
        }
    });

    //
    // Uncaught exceptions
    //
    process.on('uncaughtException', async (err) => {
        log.exception('Uncaught exception.', err);

        let exitCode = EXIT_UNCAUGHT_EXCEPTION;
        try {
            await invokeTerminationCallbacks(EXIT_UNCAUGHT_EXCEPTION);
        }
        catch (err: any) {
            log.exception('Error during uncaught exception shutdown.', err);
            exitCode = EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED;
        }
        finally {
            process.exit(exitCode);
        }
    });

    //
    // Unhandled promise rejections
    //
    process.on('unhandledRejection', async (reason: string, promise) => {
        log.exception('Unhandled promise rejection.', new Error(reason));

        let exitCode = EXIT_UNHANDLED_REJECTION;
        try {
            await invokeTerminationCallbacks(EXIT_UNHANDLED_REJECTION);
        }
        catch (err: any) {
            log.exception('Error during unhandled rejection shutdown.', err);
            exitCode = EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED;
        }
        finally {
            process.exit(exitCode);
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
