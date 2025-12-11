import { registerDebugData } from 'debug-server';
import { sleep } from 'utils';

export interface ITestDebugCommandOptions {
    verbose?: boolean;
}

//
// Temporary command for testing the debug REST API.
// Runs an infinite loop that updates debug data with random numbers.
//
export async function testDebugCommand(options: ITestDebugCommandOptions): Promise<void> {
    let iteration = 0;
    
    console.log("Starting test-debug command. Press Ctrl+C to stop.");
    console.log("Debug data will update every 3 seconds.");
    
    while (true) {
        const randomNumber = Math.floor(Math.random() * 1000000);
        registerDebugData("randomNumber", randomNumber);
        registerDebugData("iteration", iteration);
        registerDebugData("timestamp", new Date().toISOString());
        
        if (options.verbose) {
            console.log(`Debug data updated: randomNumber=${randomNumber}, iteration=${iteration}`);
        }
        
        iteration++;
        
        // Sleep for 3 seconds
        await sleep(3000);
    }
}

