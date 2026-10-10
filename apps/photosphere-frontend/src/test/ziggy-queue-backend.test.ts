import { ZiggyQueueBackend } from '../lib/ziggy-queue-backend';
import { FakeZiggy } from './fake-ziggy';
import type { ITaskResult } from 'task-queue';
import { TaskPriority, TaskStatus } from 'task-queue';

describe('ZiggyQueueBackend', () => {
    test('addTask sends the add-task message with no priority when the task has none', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);

        backend.addTask('my-type', { foo: 1 }, 'my-source', 'my-task-id');

        expect(ziggy.sent).toEqual([
            {
                channel: 'add-task',
                data: { taskType: 'my-type', data: { foo: 1 }, source: 'my-source', taskId: 'my-task-id', priority: null },
            },
        ]);
    });

    test('addTask sends the priority as its text so the core can put a tap at the head of the queue', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);

        backend.addTask('my-type', { foo: 1 }, 'my-source', 'my-task-id', TaskPriority.Interactive);

        expect(ziggy.sent).toEqual([
            {
                channel: 'add-task',
                data: { taskType: 'my-type', data: { foo: 1 }, source: 'my-source', taskId: 'my-task-id', priority: 'interactive' },
            },
        ]);
    });

    test('addTask makes up a task id when none is given and returns it', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);

        const taskId = backend.addTask('my-type', null, 'my-source');

        expect(taskId.length).toBeGreaterThan(0);
        expect(ziggy.sent[0].data).toMatchObject({ taskId });
    });

    test('addTask fires the onTaskAdded callbacks of the source', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        const added: string[] = [];
        backend.onTaskAdded('my-source', taskId => { added.push(taskId); });

        backend.addTask('my-type', null, 'other-source', 'other-task');
        backend.addTask('my-type', null, 'my-source', 'my-task');

        expect(added).toEqual(['my-task']);
    });

    test('incoming task-completed event triggers onTaskComplete callbacks', async () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        const results: ITaskResult[] = [];
        backend.onTaskComplete((result) => { results.push(result); });

        const taskResult: ITaskResult = {
            taskId: 'task-1',
            type: 'my-type',
            inputs: {},
            status: TaskStatus.Succeeded,
        };
        ziggy.emit('task-completed', { taskId: 'task-1', result: taskResult as any });

        // notifyCompletionCallbacks is async, so flush microtasks
        await Promise.resolve();

        expect(results).toHaveLength(1);
        expect(results[0]).toEqual(taskResult);
    });

    test('incoming task-message event triggers onTaskMessage and onAnyTaskMessage callbacks', async () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        const typedMessages: any[] = [];
        const anyMessages: any[] = [];
        backend.onTaskMessage('progress', (data) => { typedMessages.push(data); });
        backend.onAnyTaskMessage((data) => { anyMessages.push(data); });

        ziggy.emit('task-message', { taskId: 'task-1', message: { type: 'progress', value: 50 } });

        await Promise.resolve();

        expect(typedMessages).toEqual([{ taskId: 'task-1', message: { type: 'progress', value: 50 } }]);
        expect(anyMessages).toHaveLength(1);
    });

    test('a task message of another type, or with no type, does not reach onTaskMessage callbacks', async () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        const typedMessages: any[] = [];
        backend.onTaskMessage('progress', (data) => { typedMessages.push(data); });

        ziggy.emit('task-message', { taskId: 'task-1', message: { type: 'other' } });
        ziggy.emit('task-message', { taskId: 'task-1', message: 'text' });
        ziggy.emit('task-message', { taskId: 'task-1', message: null });
        ziggy.emit('task-message', { taskId: 'task-1', message: ['progress'] });

        await Promise.resolve();

        expect(typedMessages).toHaveLength(0);
    });

    test('cancelTasks sends the source as a bare string', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);

        backend.cancelTasks('my-source');

        expect(ziggy.sent).toEqual([{ channel: 'cancel-tasks', data: 'my-source' }]);
    });

    test('cancelTasks fires the onTasksCancelled callbacks of the source', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        let cancelled = 0;
        backend.onTasksCancelled('my-source', () => { cancelled++; });

        backend.cancelTasks('other-source');
        backend.cancelTasks('my-source');

        expect(cancelled).toBe(1);
    });

    test('unsubscribe functions remove only their registered callback', async () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);
        const firedA: ITaskResult[] = [];
        const firedB: ITaskResult[] = [];
        const unsubA = backend.onTaskComplete((result) => { firedA.push(result); });
        backend.onTaskComplete((result) => { firedB.push(result); });

        unsubA();

        const taskResult: ITaskResult = {
            taskId: 'task-1',
            type: 'my-type',
            inputs: {},
            status: TaskStatus.Succeeded,
        };
        ziggy.emit('task-completed', { taskId: 'task-1', result: taskResult as any });
        await Promise.resolve();

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });

    test('shutdown removes the bridge listeners', () => {
        const ziggy = new FakeZiggy();
        const backend = new ZiggyQueueBackend(ziggy);

        backend.shutdown();

        expect(ziggy.removed).toEqual(['task-completed', 'task-message']);
    });
});
