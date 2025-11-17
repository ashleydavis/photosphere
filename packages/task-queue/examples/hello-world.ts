import { TaskQueue } from "../src/lib/task-queue";
import { join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";

//
// Hello World example demonstrating basic task queue usage
//

async function main() {
    console.log("Creating task queue...");
    
    // Create a task queue with 2 workers
    const queue = new TaskQueue(2);

    // Register a simple "hello-world" task handler
    queue.registerHandler("hello-world", async (data, workingDirectory) => {
        console.log(`[Task Handler] Processing task with data:`, data);
        console.log(`[Task Handler] Working directory: ${workingDirectory}`);
        
        // Create the working directory if needed
        await mkdir(workingDirectory, { recursive: true });
        
        // Create a simple output file
        const outputFile = join(workingDirectory, "output.txt");
        const message = `Hello, ${data.name || "World"}!`;
        await writeFile(outputFile, message, "utf-8");
        
        console.log(`[Task Handler] Created file: ${outputFile}`);
        console.log(`[Task Handler] Message: ${message}`);
        
        // Return a status message
        return `Successfully created hello world file for ${data.name || "World"}`;
    });

    console.log("\nAdding tasks to queue...");
    
    // Add some tasks
    const task1Id = queue.addTask("hello-world", { name: "Alice" });
    console.log(`Added task 1 with ID: ${task1Id}`);
    
    const task2Id = queue.addTask("hello-world", { name: "Bob" });
    console.log(`Added task 2 with ID: ${task2Id}`);
    
    const task3Id = queue.addTask("hello-world", { name: "Charlie" });
    console.log(`Added task 3 with ID: ${task3Id}`);

    // Check initial status
    console.log("\nInitial queue status:");
    const initialStatus = queue.getStatus();
    console.log(`  Pending: ${initialStatus.pending}`);
    console.log(`  Running: ${initialStatus.running}`);
    console.log(`  Completed: ${initialStatus.completed}`);
    console.log(`  Failed: ${initialStatus.failed}`);

    // Wait for all tasks to complete
    console.log("\nWaiting for all tasks to complete...");
    await queue.awaitAllTasks();

    // Check final status
    console.log("\nFinal queue status:");
    const finalStatus = queue.getStatus();
    console.log(`  Pending: ${finalStatus.pending}`);
    console.log(`  Running: ${finalStatus.running}`);
    console.log(`  Completed: ${finalStatus.completed}`);
    console.log(`  Failed: ${finalStatus.failed}`);

    // Get results for each task
    console.log("\nTask results:");
    const result1 = await queue.awaitTask(task1Id);
    console.log(`  Task 1 (${task1Id}): ${result1.status} - ${result1.message}`);
    
    const result2 = await queue.awaitTask(task2Id);
    console.log(`  Task 2 (${task2Id}): ${result2.status} - ${result2.message}`);
    
    const result3 = await queue.awaitTask(task3Id);
    console.log(`  Task 3 (${task3Id}): ${result3.status} - ${result3.message}`);

    // Cleanup
    console.log("\nShutting down task queue...");
    queue.shutdown();
    
    console.log("\nExample completed!");
}

// Run the example
main().catch((error) => {
    console.error("Error running example:", error);
    process.exit(1);
});

