import { sleep } from 'utils';
import { ICommandContext } from '../lib/init-cmd';

export interface ITestDebugCommandOptions {
    verbose?: boolean;
}

//
// Temporary command for testing the debug REST API.
// Creates tasks that run in workers and displays worker/task state in the debug API.
//
export async function testDebugCommand(context: ICommandContext, options: ITestDebugCommandOptions): Promise<void> {
    const taskQueue = await context.taskQueueProvider.create();
    
    // Note: Worker state callback is automatically registered by TaskQueueProvider when --debug is enabled
    // Note: test-sleep handler is registered in worker.ts via initTaskHandlers()
    
    console.log("Starting test-debug command. Press Ctrl+C to stop.");
    console.log("Creating tasks that will run in workers...");
    
    // Create a bunch of tasks with random sleep times
    const taskIds: string[] = [];
    for (let i = 0; i < 20; i++) {
        const sleepMs = Math.floor(Math.random() * 5000) + 1000; // 1-6 seconds
        const taskId = taskQueue.addTask("test-sleep", { sleepMs, taskNumber: i + 1 });
        taskIds.push(taskId);
        if (options.verbose) {
            console.log(`Created task ${i + 1}: ${taskId} (will sleep for ${sleepMs}ms)`);
        }
    }
    
    // Wait for all tasks to complete, then create more
    while (true) {
        await taskQueue.awaitAllTasks();
        
        if (options.verbose) {
            console.log("All tasks completed. Creating more...");
        }
        
        // Create more tasks
        for (let i = 0; i < 20; i++) {
            const sleepMs = Math.floor(Math.random() * 5000) + 1000;
            taskQueue.addTask("test-sleep", { sleepMs, taskNumber: i + 1 });
        }
    }
}

