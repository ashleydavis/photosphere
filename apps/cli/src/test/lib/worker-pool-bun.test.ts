jest.mock('node-api', () => ({
    initTaskHandlers: jest.fn(),
}));
jest.mock('task-queue', () => ({
    TaskStatus: {
        Pending: "pending",
    },
    insertTaskByPriority: (pendingTasks: any[], task: any) => {
        pendingTasks.push(task);
    },
    resolveTaskPriority: () => 0,
}));

import { WorkerPoolBun } from '../../lib/worker-pool-bun';

//
// A stand-in for a Bun worker thread that records what the pool asks of it and fires "close" only
// when the test says the thread has ended.
//
class FakeWorker {
    // Every fake worker the pool has started in the current test, in the order they were started.
    static started: FakeWorker[] = [];

    // Listeners the pool registered, by event type.
    listeners: Map<string, ((event: any) => void)[]> = new Map();

    // Every message the pool posted to this worker.
    posted: any[] = [];

    // How many times the pool called terminate on this worker.
    terminateCalls = 0;

    constructor() {
        FakeWorker.started.push(this);
    }

    addEventListener(type: string, listener: (event: any) => void): void {
        const existing = this.listeners.get(type) ?? [];
        existing.push(listener);
        this.listeners.set(type, existing);
    }

    postMessage(message: any): void {
        this.posted.push(message);
    }

    terminate(): void {
        this.terminateCalls++;
    }

    // Delivers an event to the pool's listeners for it.
    fire(type: string, event: any): void {
        for (const listener of this.listeners.get(type) ?? []) {
            listener(event);
        }
    }
}

//
// Starts a pool with one worker that has reported ready, the state a command leaves it in.
//
function startPoolWithOneWorker(): WorkerPoolBun {
    const pool = new WorkerPoolBun(1, 600000, {});
    pool.addTask("some-task", {}, "some-source");
    expect(FakeWorker.started.length).toBe(1);
    FakeWorker.started[0].fire("message", {
        data: {
            type: "worker-ready",
        },
    });
    return pool;
}

describe('WorkerPoolBun.shutdown', () => {
    let originalWorker: any;

    beforeEach(() => {
        originalWorker = (global as any).Worker;
        (global as any).Worker = FakeWorker;
        FakeWorker.started = [];
    });

    afterEach(() => {
        (global as any).Worker = originalWorker;
        jest.useRealTimers();
    });

    test('asks each worker to end its own thread instead of terminating it', async () => {
        const pool = startPoolWithOneWorker();
        const worker = FakeWorker.started[0];

        const shutdown = pool.shutdown();
        worker.fire("close", {});
        await shutdown;

        expect(worker.posted[worker.posted.length - 1]).toEqual({
            type: "shutdown",
        });
        expect(worker.terminateCalls).toBe(0);
    });

    test('does not resolve until every worker thread has closed', async () => {
        const pool = startPoolWithOneWorker();
        const worker = FakeWorker.started[0];

        let resolved = false;
        const shutdown = pool.shutdown().then(() => {
            resolved = true;
        });
        await new Promise(resolve => setImmediate(resolve));
        expect(resolved).toBe(false);

        worker.fire("close", {});
        await shutdown;
        expect(resolved).toBe(true);
    });

    test('fails loudly when a worker thread never closes', async () => {
        jest.useFakeTimers();
        const pool = startPoolWithOneWorker();

        const shutdown = pool.shutdown();
        jest.advanceTimersByTime(60_000);

        await expect(shutdown).rejects.toThrow("1 of 1 worker threads had not closed 60 seconds after being asked to shut down.");
    });
});
