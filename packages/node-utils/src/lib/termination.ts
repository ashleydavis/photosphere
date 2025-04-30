
//
// Register a callback function to be called when the process is about to exit.
//
export function registerTerminationCallback(callback: () => Promise<void>): void {

    // Listen for the SIGTERM signal (graceful shutdown request)
    process.on('SIGTERM', async () => {
        console.log('SIGTERM received. Shutting down gracefully...');

        try {
            await callback();
        }
        catch (err: any) {
            console.error('Error during SIGTERM shutdown:');
            console.error(err.stack || err.message || err);
        }
        finally {
            process.exit(0);
        }

    });

    // Listen for the SIGINT signal (Ctrl+C)
    process.on('SIGINT', async () => {
        console.log('SIGINT received. Shutting down...');
        
        try {
            await callback();
        }
        catch (err: any) {
            console.error('Error during SIGINT shutdown:');
            console.error(err.stack || err.message || err);
        }
        finally {
            process.exit(0);
        }
    });

    // Uncaught exceptions
    process.on('uncaughtException', async (error) => {
        console.error('Uncaught exception:');
        console.error(error.stack || error.message || error);

        try {
            await callback();
        }
        catch (err: any) {
            console.error('Error during uncaught exception shutdown:');
            console.error(err.stack || err.message || err);
        }
        finally {
            process.exit(1);
        }
    });

    // Unhandled promise rejections
    process.on('unhandledRejection', async (reason, promise) => {
        console.error('Unhandled promise rejection:', reason);

        try {
            await callback();
        }
        catch (err: any) {
            console.error('Error during unhandled rejection shutdown:');
            console.error(err.stack || err.message || err);
        }
        finally {
            process.exit(1);
        }
    });

    // Before exit (not called on explicit process.exit())
    process.on('beforeExit', (code) => {
        console.log(`Process beforeExit with code: ${code}`);
        // Perform synchronous cleanup.
    });

    // Exit event (called for all exits)
    process.on('exit', (code) => {
        console.log(`Process exiting with code: ${code}`);
        // Only synchronous operations will work here.
    });
}
