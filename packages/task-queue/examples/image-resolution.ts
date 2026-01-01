import { TaskQueue, TaskStatus, ITaskResult } from "../src";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import pc from "picocolors";

//
// Image Resolution Example
// Demonstrates processing multiple images with callbacks and result queries
//

async function main() {
    console.log(pc.bold(pc.blue("--- Image Resolution Example ---\n")));

    const baseWorkingDirectory = join(tmpdir(), "task-queue");
    const uuidGenerator = { generate: () => randomUUID() };
    const queue = new TaskQueue(4, "./worker.ts", baseWorkingDirectory, uuidGenerator, 600000, undefined);

    // Register handler for getting image resolution
    // Note: This is a simplified example - in a real implementation you'd use
    // an actual image processing library like 'sharp' or 'image-size'
    // The task queue will automatically catch any errors thrown here
    queue.registerHandler("get-image-resolution", async (data, workingDirectory) => {
        const { imagePath } = data;
        
        // Check if file exists
        if (!existsSync(imagePath)) {
            throw new Error(`File not found: ${imagePath}`);
        }

        // Read image file
        const imageBuffer = await readFile(imagePath);
        
        // In a real implementation, you would use an image library here
        // For this example, we'll simulate getting dimensions
        // const dimensions = imageSize(imageBuffer);
        
        // Simulated dimensions for demonstration
        const dimensions = {
            width: Math.floor(Math.random() * 2000) + 100,
            height: Math.floor(Math.random() * 2000) + 100
        };
        
        // Return the resolution as outputs
        return {
            width: dimensions.width,
            height: dimensions.height,
            path: imagePath
        };
    });

    // Register callback to print results as tasks complete
    queue.onTaskComplete((result: ITaskResult) => {
        if (result.status === TaskStatus.Completed) {
            const { width, height, path } = result.outputs;
            console.log(pc.green(`✓ ${path}: ${width}x${height}`));
        } else if (result.status === TaskStatus.Failed) {
            // Parse the serialized error
            const errorObj = JSON.parse(result.error || "{}");
            console.error(pc.red(`✗ ${result.taskType} failed: ${errorObj.message}`));
        }
    });

    // Add multiple image processing tasks
    // Using test images from the project if they exist, otherwise using placeholder paths
    const testImageDir = join(process.cwd(), "test");
    const imagePaths = [
        join(testImageDir, "test.jpg"),
        join(testImageDir, "test.png"),
        join(testImageDir, "test.webp"),
        "/path/to/nonexistent.jpg", // This will fail
    ];

    console.log("Adding image processing tasks...\n");
    const taskIds = imagePaths.map(path => 
        queue.addTask("get-image-resolution", { imagePath: path })
    );

    // Wait for all tasks to complete
    console.log("Processing images...\n");
    await queue.awaitAllTasks();

    // Get summary
    const successful = queue.getSuccessfulTaskResults();
    const failed = queue.getFailedTaskResults();

    console.log(pc.bold(`\nSummary: ${pc.green(successful.length)} succeeded, ${pc.red(failed.length)} failed`));

    // Print all successful results
    if (successful.length > 0) {
        console.log(pc.bold("\nSuccessful resolutions:"));
        for (const result of successful) {
            const { width, height, path } = result.outputs;
            console.log(`  ${path}: ${width}x${height}`);
        }
    }

    // Print all failures
    if (failed.length > 0) {
        console.log(pc.bold("\nFailed tasks:"));
        for (const result of failed) {
            const errorObj = JSON.parse(result.error || "{}");
            console.log(`  ${result.taskId}: ${errorObj.message}`);
        }
    }

    // Demonstrate accessing inputs from results
    console.log(pc.bold("\nTask inputs (original arguments):"));
    for (const result of queue.getAllTaskResults()) {
        console.log(`  Task ${result.taskId}:`, result.inputs);
    }

    queue.shutdown();
    console.log(pc.bold(pc.blue("\n--- Example Finished ---")));
}

main().catch((error) => {
    console.error("Error running example:", error);
    process.exit(1);
});

