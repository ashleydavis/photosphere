# Task Queue Examples

This directory contains example code demonstrating how to use the task-queue package.

## Hello World Example

The `hello-world.ts` example demonstrates the basic usage of the task queue:

1. Creating a task queue
2. Registering a task handler
3. Adding tasks to the queue
4. Waiting for tasks to complete
5. Retrieving task results

### Running the Example

```bash
cd packages/task-queue
bun run examples/hello-world.ts
```

### What It Does

The example:
- Creates a task queue with 2 workers
- Registers a "hello-world" handler that creates a file in the task's working directory
- Adds 3 tasks with different names (Alice, Bob, Charlie)
- Waits for all tasks to complete
- Displays the results

Each task creates a file in its own temporary working directory with a personalized greeting message.

## Image Resolution Example

The `image-resolution.ts` example demonstrates advanced features of the task queue:

1. Using completion callbacks to process results as tasks complete
2. Querying results for successful and failed tasks separately
3. Accessing both inputs and outputs from task results
4. Error handling and serialization

### Running the Example

```bash
cd packages/task-queue
bun run examples/image-resolution.ts
```

### What It Does

The example:
- Creates a task queue with 4 workers
- Registers a "get-image-resolution" handler that processes image files
- Registers a completion callback that prints results as each task completes
- Adds multiple image processing tasks (some will succeed, some will fail)
- Waits for all tasks to complete
- Queries and displays successful and failed tasks separately
- Demonstrates accessing both the original inputs and the result outputs

This example shows how to use callbacks for real-time progress updates and how to query results by status.
