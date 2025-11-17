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

