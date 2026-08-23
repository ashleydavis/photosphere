import type { IQueueBackend, ITaskContext, TaskMessageCallback, UnsubscribeFn, WorkerTaskCompletionCallback } from 'task-queue';
import { setQueueBackend, TaskPriority } from 'task-queue';

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock('../../lib/open-storage', () => ({
    openStorage: jest.fn().mockResolvedValue({ storage: {}, s3Config: undefined, storageOptions: {} }),
}));

jest.mock('../../lib/media-file-database', () => ({
    isDatabasePartial: jest.fn(),
    createLazyDatabaseStorage: jest.fn().mockResolvedValue({}),
    createMediaFileDatabase: jest.fn().mockReturnValue({
        metadataCollection: {
            sortIndex: jest.fn().mockReturnValue({
                // One empty page, so the handler streams nothing and goes straight to the prefetch
                // decision, which is what these tests are about.
                getPage: jest.fn().mockResolvedValue({ records: [], nextPageId: undefined }),
            }),
        },
    }),
}));

import { loadAssetsHandler } from '../../lib/load-assets.worker';
import { isDatabasePartial } from '../../lib/media-file-database';

const mockIsDatabasePartial = isDatabasePartial as jest.MockedFunction<typeof isDatabasePartial>;

// ── helpers ──────────────────────────────────────────────────────────────────

//
// What one call to addTask was given, so a test can assert on the priority it asked for.
//
interface IRecordedTask {
    // The handler name.
    type: string;

    // The priority asked for, or undefined when none was named.
    priority: TaskPriority | undefined;
}

//
// A queue backend that records what it was asked to add and never completes anything. The handler
// queues the prefetch and does not wait for it, so nothing here needs to finish.
//
class RecordingBackend implements IQueueBackend {
    //
    // Every task added through this backend, in order.
    //
    readonly addedTasks: IRecordedTask[] = [];

    addTask(type: string, _data: any, _source: string, taskId?: string, priority?: TaskPriority): string {
        this.addedTasks.push({ type, priority });
        return taskId ?? 'generated-id';
    }

    onTaskAdded(_source: string, _callback: (taskId: string) => void): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onTaskComplete(_callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onTaskMessage(_messageType: string, _callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    onAnyTaskMessage(_callback: TaskMessageCallback): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    cancelTasks(_source: string): void {
        // Nothing to cancel.
    }

    onTasksCancelled(_source: string, _callback: () => void): UnsubscribeFn {
        return () => { /* nothing subscribed. */ };
    }

    shutdown(): void {
        // Nothing to shut down.
    }
}

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: { generate: () => 'test-uuid' },
        timestampProvider: { now: () => Date.now(), dateNow: () => new Date() },
        sessionId: 'session-1',
        maxConcurrentChildTasks: 10,
        taskId: 'load-assets-task',
        sendMessage: jest.fn(),
        isCancelled: () => false,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

describe('loadAssetsHandler', () => {
    let backend: RecordingBackend;

    beforeEach(() => {
        jest.clearAllMocks();
        backend = new RecordingBackend();
        setQueueBackend(backend);
    });

    test('queues the thumbnail prefetch of a partial database as background work', async () => {
        mockIsDatabasePartial.mockResolvedValue(true);

        await loadAssetsHandler({ databasePath: '/test/db' }, makeContext());

        const prefetchTasks = backend.addedTasks.filter(task => task.type === 'prefetch-database');
        expect(prefetchTasks).toHaveLength(1);
        // Explicitly background: without it the prefetch inherits this task's interactive priority
        // and holds a worker for as long as it takes to pull down every thumbnail.
        expect(prefetchTasks[0].priority).toBe(TaskPriority.Background);
    });

    test('queues no prefetch for a database that is not partial', async () => {
        mockIsDatabasePartial.mockResolvedValue(false);

        await loadAssetsHandler({ databasePath: '/test/db' }, makeContext());

        expect(backend.addedTasks.filter(task => task.type === 'prefetch-database')).toHaveLength(0);
    });
});
