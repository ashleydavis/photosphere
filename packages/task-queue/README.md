# task-queue

A task queue system using Bun workers for parallel task execution. This package provides a simple interface for queuing and executing tasks in parallel using Bun's worker threads.

## Todo

- Default max workers to num cpus.
- Each task needs to return json results.
    - I need to be able to accumulate those.
- Check all times and uuids come from the providers.
- Crashed tasks.
- Task timeout.
- Dispatch next task when worker is idle.
- Lazily create workers up to maximum.
- Set max workers as an arg.
- Allocate multiple tasks to each worker (maybe, can we see how loaded each task is).


## Features

- **Parallel Execution**: Execute multiple tasks concurrently using Bun workers
- **Task Status Tracking**: Monitor task status (pending, running, completed, failed)
- **Task Results**: Get full results including outputs, errors, and metadata
- **Completion Callbacks**: Register callbacks to be notified when tasks complete
- **Result Queries**: Get results for individual tasks, all tasks, successful tasks, or failed tasks
- **Isolated Working Directories**: Each task gets its own temporary working directory
- **Type-Safe**: Full TypeScript support with comprehensive type definitions
- **Promise-Based**: Use async/await for task completion

## Installation

```bash
bun add task-queue
```

## Usage

### Basic Example

```typescript
import { TaskQueue, ITaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

// Create a task queue with 4 workers
const baseWorkingDirectory = join(tmpdir(), "task-queue");
const uuidGenerator = new RandomUuidGenerator();
const queue = new TaskQueue(4, "./worker.ts", baseWorkingDirectory, uuidGenerator, 2400000, {});

// Register a task handler
queue.registerHandler("process-image", async (data, workingDirectory) => {
    // data contains the task inputs (parameters object)
    const { imagePath, outputFormat } = data;
    
    // workingDirectory is a unique path for this task
    // You can create files here if needed
    const outputPath = `${workingDirectory}/output.${outputFormat}`;
    
    // Do your work here
    // ... process the image ...
    
    // Return the result outputs (can be any type: object, string, number, etc.)
    return {
        success: true,
        outputPath: outputPath,
        originalPath: imagePath,
        format: outputFormat
    };
});

// Add a task to the queue with parameters
const taskId = queue.addTask("process-image", {
    imagePath: "/path/to/image.jpg",
    outputFormat: "png"
});

// Wait for the task to complete
const result = await queue.awaitTask(taskId);
console.log(result.status); // "completed"
console.log(result.outputs); // { success: true, outputPath: "...", ... }

// Clean up
queue.shutdown();
```

### Multiple Tasks

```typescript
import { TaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

const baseWorkingDirectory = join(tmpdir(), "task-queue");
const uuidGenerator = new RandomUuidGenerator();
const queue = new TaskQueue(4, "./worker.ts", baseWorkingDirectory, uuidGenerator, 2400000, {});

// Register handler
queue.registerHandler("upload-file", async (data, workingDirectory) => {
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
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

const baseWorkingDirectory = join(tmpdir(), "task-queue");
const uuidGenerator = new RandomUuidGenerator();
const queue = new TaskQueue(4, "./worker.ts", baseWorkingDirectory, uuidGenerator, 2400000, {});

// Register a completion callback
queue.onTaskComplete((result: ITaskResult) => {
    if (result.status === TaskStatus.Completed) {
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
await queue.awaitTask(taskId);
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
await queue.awaitTask(taskId);

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
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

const baseWorkingDirectory = join(tmpdir(), "task-queue");
const uuidGenerator = new RandomUuidGenerator();
const queue = new TaskQueue(2, "./worker.ts", baseWorkingDirectory, uuidGenerator, 2400000, {});

queue.registerHandler("long-running-task", async (data, workingDirectory) => {
    // Simulate long-running work
    await new Promise(resolve => setTimeout(resolve, 5000));
    return "Task completed";
});

const taskId = queue.addTask("long-running-task", { data: "test" });

// Check status without waiting
const status = queue.taskStatus(taskId);
console.log(status?.status); // "pending", "running", "completed", or "failed"

// Or wait for completion
const result = await queue.awaitTask(taskId);
console.log(result.status); // "completed"
console.log(result.message); // "Task completed"
```

### Error Handling

```typescript
import { TaskQueue, TaskStatus } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { join } from "node:path";
import { tmpdir } from "node:os";

const baseWorkingDirectory = join(tmpdir(), "task-queue");
const uuidGenerator = new RandomUuidGenerator();
const queue = new TaskQueue(2, "./worker.ts", baseWorkingDirectory, uuidGenerator, 2400000, {});

queue.registerHandler("risky-task", async (data, workingDirectory) => {
    if (data.shouldFail) {
        throw new Error("Task failed intentionally");
    }
    return "Task succeeded";
});

const taskId = queue.addTask("risky-task", { shouldFail: true });

const result = await queue.awaitTask(taskId);
if (result.status === TaskStatus.Failed) {
    console.error("Task failed:", result.error);
} else {
    console.log("Task succeeded:", result.message);
}
```

### Working Directory Usage

Each task receives a unique working directory path. The directory is not created automatically - you can create it lazily if needed:

```typescript
import { TaskQueue } from "task-queue";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

const queue = new TaskQueue(2);

queue.registerHandler("file-operation", async (data, workingDirectory) => {
    // Create the working directory if needed
    await mkdir(workingDirectory, { recursive: true });
    
    // Create files in the working directory
    const outputFile = join(workingDirectory, "output.txt");
    await writeFile(outputFile, data.content);
    
    return `Created file: ${outputFile}`;
});

const taskId = queue.addTask("file-operation", {
    content: "Hello, World!"
});

const result = await queue.awaitTask(taskId);
console.log(result.message);
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
    "./worker.ts", // worker path
    customWorkingDir, // base working directory
    uuidGenerator, // UUID generator
    2400000, // task timeout (40 minutes)
    {} // worker options
);
```

## API Reference

### `ITaskQueue`

The main interface for the task queue.

#### Methods

- **`addTask(type: string, data: any): string`**
  - Adds a task to the queue
  - Returns the task ID (UUID)
  - Parameters:
    - `type`: The task type (must have a registered handler)
    - `data`: Task inputs (any serializable data)

- **`registerHandler(type: string, handler: TaskHandler): void`**
  - Registers a handler for a task type
  - Parameters:
    - `type`: The task type name
    - `handler`: Async function that processes the task
      - Signature: `(data: any, workingDirectory: string) => Promise<any>`
      - Returns the result outputs (can be any type: object, string, number, etc.)

- **`onTaskComplete(callback: TaskCompletionCallback): void`**
  - Registers a callback that will be invoked when any task completes (success or failure)
  - Parameters:
    - `callback`: Function that receives the task result
      - Signature: `(result: ITaskResult) => void`

- **`awaitTask(id: string): Promise<ITaskResult>`**
  - Waits for a specific task to complete
  - Returns a promise that resolves with the task result

- **`taskStatus(id: string): ITaskResult | undefined`**
  - Gets the current status of a task without waiting
  - Returns `undefined` if task not found
  - Returns full result including outputs, error, and metadata

- **`getTaskResult(id: string): ITaskResult | undefined`**
  - Gets the full result of a specific task (including outputs)
  - Returns `undefined` if task not found
  - Same as `taskStatus()` but more explicit about returning full results

- **`getAllTaskResults(): ITaskResult[]`**
  - Gets results for all tasks (pending, running, completed, and failed)
  - Returns an array of all task results

- **`getSuccessfulTaskResults(): ITaskResult[]`**
  - Gets results for all successfully completed tasks
  - Returns an array of completed task results

- **`getFailedTaskResults(): ITaskResult[]`**
  - Gets results for all failed tasks
  - Returns an array of failed task results with error details

- **`awaitAllTasks(): Promise<void>`**
  - Waits for all pending and running tasks to complete
  - Resolves when the queue is empty

- **`getStatus(): IQueueStatus`**
  - Gets overall queue status
  - Returns an object with:
    - `pending`: Number of pending tasks
    - `running`: Number of running tasks
    - `completed`: Number of completed tasks
    - `failed`: Number of failed tasks
    - `total`: Total number of tasks

### `TaskStatus`

Enumeration of task statuses:
- `Pending`: Task is queued but not yet started
- `Running`: Task is currently executing
- `Completed`: Task completed successfully
- `Failed`: Task failed with an error

### `ITaskResult`

Task result object:
```typescript
{
    status: TaskStatus;
    message?: string;      // Status message (auto-generated if outputs is string)
    error?: string;        // Serialized error object as JSON string (if failed)
    outputs?: any;         // The actual result data returned by the handler
    inputs: any;           // The original arguments/data sent to the task
    taskId: string;        // The task ID
    taskType: string;      // The task type
    createdAt: Date;       // When the task was created
    startedAt?: Date;      // When the task started executing
    completedAt?: Date;    // When the task completed (or failed)
}
```

**Note**: The `error` field contains a JSON-serialized error object with `message`, `stack`, `name`, and other error properties. You can parse it with `JSON.parse(result.error)` to access the full error details.

### `IQueueStatus`

Queue status object:
```typescript
{
    pending: number;
    running: number;
    completed: number;
    failed: number;
    total: number;
}
```

## Requirements

- Bun runtime (this package uses Bun workers)
- TypeScript 5.6+ (for type definitions)

## License

MIT

