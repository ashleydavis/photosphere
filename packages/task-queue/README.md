# task-queue

A task queue system using Bun workers for parallel task execution. This package provides a simple interface for queuing and executing tasks in parallel using Bun's worker threads.

## Setup

Open a terminal and change directory to the task-queue project:

```bash
cd photosphere/packages/task-queue
```

Install dependencies:

```bash
bun install
```

## Compile

Compile the code:

```bash
bun run compile
```

Compile with live reload:

```bash
bun run compile:watch
```

## Run automated tests

```bash
bun test
```

## Usage

### Basic Example

```typescript
import { TaskQueue, ITaskQueue, ITaskResult } from "task-queue";

// Create a task queue with 4 workers
const queue = new TaskQueue(4);

// Register a task handler
queue.registerHandler("process-image", async (data) => {
    // data contains the task inputs (parameters object)
    const { imagePath, outputFormat } = data;
    
    // Do your work here
    // ... process the image ...
    
    // Return the result outputs (can be any type: object, string, number, etc.)
    return {
        success: true,
        originalPath: imagePath,
        format: outputFormat
    };
});

// Add a task to the queue with parameters
const taskId = queue.addTask("process-image", {
    imagePath: "/path/to/image.jpg",
    outputFormat: "png"
});

// Wait for the task to complete using a callback
let result: ITaskResult | undefined;
queue.onTaskComplete((task, taskResult) => {
    if (taskResult.taskId === taskId) {
        result = taskResult;
    }
});

// Wait for all tasks to complete
await queue.awaitAllTasks();

console.log(result?.status); // "succeeded"
console.log(result?.outputs); // { success: true, outputPath: "...", ... }

// Clean up
queue.shutdown();
```

### Multiple Tasks

```typescript
import { TaskQueue } from "task-queue";

const queue = new TaskQueue(4);

// Register handler
queue.registerHandler("upload-file", async (data) => {
    const { filePath, destination } = data;
    // Upload logic here
    return `Uploaded ${filePath} to ${destination}`;
});

// Add multiple tasks
const taskIds = [
    queue.addTask("upload-file", { filePath: "file1.txt", destination: "s3://bucket/" }),
    queue.addTask("upload-file", { filePath: "file2.txt", destination: "s3://bucket/" }),
    queue.addTask("upload-file", { filePath: "file3.txt", destination: "s3://bucket/" }),
];

// Wait for all tasks to complete
await queue.awaitAllTasks();

// Check status
const status = queue.getStatus();
console.log(`Completed: ${status.completed}, Failed: ${status.failed}`);

queue.shutdown();
```

### Task Completion Callbacks

Register a callback to be notified when tasks complete:

```typescript
import { TaskQueue, TaskStatus, ITaskResult } from "task-queue";

const queue = new TaskQueue(4);

// Register a completion callback
queue.onTaskComplete((result: ITaskResult) => {
    if (result.status === TaskStatus.Succeeded) {
        console.log(`Task ${result.taskId} succeeded:`, result.outputs);
    } else if (result.status === TaskStatus.Failed) {
        console.error(`Task ${result.taskId} failed:`, result.error);
    }
});

queue.registerHandler("my-task", async (data) => {
    return { processed: true, data };
});

const taskId = queue.addTask("my-task", { value: 123 });
// Callback will be invoked when task completes
await queue.awaitAllTasks();
```

### Getting Task Results

You can query results in multiple ways:

```typescript
import { TaskQueue, TaskStatus } from "task-queue";

const queue = new TaskQueue(4);

queue.registerHandler("test-task", async (data) => {
    return { result: data.value * 2 };
});

const taskId = queue.addTask("test-task", { value: 21 });
await queue.awaitAllTasks();

// Get result of a specific task
const result = queue.getTaskResult(taskId);
console.log(result?.outputs); // { result: 42 }

// Get all task results
const allResults = queue.getAllTaskResults();

// Get only successful tasks
const successful = queue.getSuccessfulTaskResults();

// Get only failed tasks
const failed = queue.getFailedTaskResults();
```

### Task Status Monitoring

```typescript
import { TaskQueue, TaskStatus } from "task-queue";

const queue = new TaskQueue(2);

queue.registerHandler("long-running-task", async (data) => {
    // Simulate long-running work
    await new Promise(resolve => setTimeout(resolve, 5000));
    return "Task completed";
});

const taskId = queue.addTask("long-running-task", { data: "test" });

// Check status without waiting
const status = queue.taskStatus(taskId);
console.log(status?.status); // "pending", "running", "succeeded", or "failed"

// Or wait for completion
await queue.awaitAllTasks();
const result = queue.getTaskResult(taskId);
console.log(result?.status); // "succeeded"
console.log(result?.outputs); // "Task completed"
```

### Error Handling

```typescript
import { TaskQueue, TaskStatus } from "task-queue";

const queue = new TaskQueue(2);

queue.registerHandler("risky-task", async (data) => {
    if (data.shouldFail) {
        throw new Error("Task failed intentionally");
    }
    return "Task succeeded";
});

const taskId = queue.addTask("risky-task", { shouldFail: true });

await queue.awaitAllTasks();
const result = queue.getTaskResult(taskId);
if (result?.status === TaskStatus.Failed) {
    console.error("Task failed:", result.error);
} else {
    console.log("Task succeeded:", result?.outputs);
}
```

### Custom Configuration

```typescript
import { TaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Custom working directory
const customWorkingDir = join(tmpdir(), "my-tasks");

// Custom UUID generator
const uuidGenerator = new RandomUuidGenerator();

// Create queue with custom settings
const queue = new TaskQueue(
    8, // max workers
    customWorkingDir, // base working directory
    uuidGenerator // UUID generator
);
```


