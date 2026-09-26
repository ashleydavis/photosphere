pub const task_queue = @import("lib/task-queue.zig");
pub const types = @import("lib/types.zig");
pub const queue_backend = @import("lib/queue-backend.zig");
pub const worker = @import("lib/worker.zig");
pub const task_context = @import("lib/task-context.zig");
pub const json_value = @import("lib/json-value.zig");
pub const job_progress = @import("lib/job-progress.zig");
pub const pending_task_queue = @import("lib/pending-task-queue.zig");

//
// The in-process test backend (TypeScript: test/mock-worker-pool.ts), exported so that other
// packages can test code that uses TaskQueue.
//
pub const mock_worker_pool = @import("test/mock-worker-pool.zig");

// Not ported: WorkerQueueBackend (worker-queue-backend.ts). Zig workers are threads of the same process
// that share the main thread's backend (setQueueBackend is process-wide), and no task handler on the
// psi replicate or psi verify path queues child tasks.
