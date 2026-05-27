import { WebSocketQueueBackend } from '../lib/websocket-queue-backend';
import type { ITaskResult } from 'task-queue';
import { TaskStatus, registerHandler } from 'task-queue';

//
// Builds a minimal WebSocket mock that captures the message listener so tests
// can simulate incoming messages.
//
function makeWebSocket() {
    let messageListener: ((event: { data: string }) => void) | null = null;
    const ws = {
        send: jest.fn(),
        addEventListener: jest.fn().mockImplementation((eventType: string, cb: any) => {
            if (eventType === 'message') {
                messageListener = cb;
            }
        }),
        // Helper: simulate an incoming WebSocket message
        _emit(data: any) {
            if (messageListener) {
                messageListener({ data: JSON.stringify(data) });
            }
        },
    };
    return ws;
}

describe('WebSocketQueueBackend', () => {
    test('addTask sends the correct JSON over the WebSocket', () => {
        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);

        backend.addTask('my-type', { foo: 1 }, 'my-source', 'my-task-id');

        expect(ws.send).toHaveBeenCalledWith(JSON.stringify({
            type: 'add-task',
            taskId: 'my-task-id',
            taskType: 'my-type',
            data: { foo: 1 },
            source: 'my-source',
        }));
    });

    test('incoming task-completed WebSocket message triggers onTaskComplete callbacks', async () => {
        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
        const results: ITaskResult[] = [];
        backend.onTaskComplete((result) => { results.push(result); });

        const taskResult: ITaskResult = {
            taskId: 'task-1',
            type: 'my-type',
            inputs: {},
            status: TaskStatus.Succeeded,
        };
        ws._emit({ type: 'task-completed', result: taskResult });

        // notifyCompletionCallbacks is async — flush microtasks
        await Promise.resolve();

        expect(results).toHaveLength(1);
        expect(results[0]).toEqual(taskResult);
    });

    test('incoming task-message WebSocket message triggers onTaskMessage and onAnyTaskMessage callbacks', async () => {
        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
        const typedMessages: any[] = [];
        const anyMessages: any[] = [];
        backend.onTaskMessage('progress', (data) => { typedMessages.push(data); });
        backend.onAnyTaskMessage((data) => { anyMessages.push(data); });

        ws._emit({ type: 'task-message', taskId: 'task-1', message: { type: 'progress', value: 50 } });

        await Promise.resolve();

        expect(typedMessages).toHaveLength(1);
        expect(anyMessages).toHaveLength(1);
    });

    test('cancelTasks sends the correct cancel message over the WebSocket', () => {
        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);

        backend.cancelTasks('my-source');

        expect(ws.send).toHaveBeenCalledWith(JSON.stringify({ type: 'cancel-tasks', source: 'my-source' }));
    });

    test('addTask runs the handler locally when one is registered and does not send over the WebSocket', async () => {
        const handlerCalls: any[] = [];
        registerHandler('local-only-task', async (data) => {
            handlerCalls.push(data);
            return { ok: true };
        });

        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
        const completions: ITaskResult[] = [];
        backend.onTaskComplete((result) => { completions.push(result); });

        backend.addTask('local-only-task', { value: 42 }, 'src', 'task-local');

        // executeLocalTask runs async — flush microtasks
        await new Promise(resolve => setImmediate(resolve));

        expect(ws.send).not.toHaveBeenCalled();
        expect(handlerCalls).toEqual([{ value: 42 }]);
        expect(completions).toHaveLength(1);
        expect(completions[0].taskId).toBe('task-local');
        expect(completions[0].status).toBe(TaskStatus.Succeeded);
        expect(completions[0].outputs).toEqual({ ok: true });
        expect(completions[0].type).toBe('local-only-task');
        expect(completions[0].inputs).toEqual({ value: 42 });
    });

    test('addTask reports Failed completion when a locally registered handler throws', async () => {
        registerHandler('local-failing-task', async () => {
            throw new Error('boom');
        });

        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
        const completions: ITaskResult[] = [];
        backend.onTaskComplete((result) => { completions.push(result); });

        backend.addTask('local-failing-task', {}, 'src', 'task-fail');

        await new Promise(resolve => setImmediate(resolve));

        expect(ws.send).not.toHaveBeenCalled();
        expect(completions).toHaveLength(1);
        expect(completions[0].status).toBe(TaskStatus.Failed);
        expect(completions[0].errorMessage).toBe('boom');
    });

    test('addTask still fires onTaskAdded callbacks when routed locally', async () => {
        registerHandler('local-added-task', async () => undefined);

        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
        const addedIds: string[] = [];
        backend.onTaskAdded('src', (taskId) => { addedIds.push(taskId); });

        backend.addTask('local-added-task', {}, 'src', 'task-added');

        await new Promise(resolve => setImmediate(resolve));

        expect(addedIds).toEqual(['task-added']);
    });

    test('unsubscribe functions remove only their registered callback', async () => {
        const ws = makeWebSocket();
        const backend = new WebSocketQueueBackend(ws as any);
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
        ws._emit({ type: 'task-completed', result: taskResult });
        await Promise.resolve();

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });
});
