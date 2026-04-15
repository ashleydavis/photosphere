import { ElectronRendererQueueBackend } from '../lib/electron-renderer-queue-backend';
import type { ITaskResult } from 'task-queue';
import { TaskStatus } from 'task-queue';

//
// Builds a minimal IElectronAPI mock.
//
function makeElectronAPI() {
    const listeners: Map<string, ((data: any) => void)[]> = new Map();
    return {
        addTask: jest.fn(),
        cancelTasks: jest.fn(),
        onMessage: jest.fn().mockImplementation((type: string, cb: (data: any) => void) => {
            const existing = listeners.get(type) ?? [];
            existing.push(cb);
            listeners.set(type, existing);
        }),
        removeAllListeners: jest.fn(),
        // Helper: simulate an incoming IPC message
        _emit(type: string, data: any) {
            const cbs = listeners.get(type) ?? [];
            for (const cb of cbs) {
                cb(data);
            }
        },
    };
}

describe('ElectronRendererQueueBackend', () => {
    test('addTask sends the correct IPC message via electronAPI.addTask', () => {
        const api = makeElectronAPI();
        const backend = new ElectronRendererQueueBackend(api as any);

        backend.addTask('my-type', { foo: 1 }, 'my-source', 'my-task-id');

        expect(api.addTask).toHaveBeenCalledWith('my-type', { foo: 1 }, 'my-source', 'my-task-id');
    });

    test('incoming task-completed IPC message triggers onTaskComplete callbacks', async () => {
        const api = makeElectronAPI();
        const backend = new ElectronRendererQueueBackend(api as any);
        const results: ITaskResult[] = [];
        backend.onTaskComplete((result) => { results.push(result); });

        const taskResult: ITaskResult = {
            taskId: 'task-1',
            type: 'my-type',
            inputs: {},
            status: TaskStatus.Succeeded,
        };
        api._emit('task-completed', { taskId: 'task-1', result: taskResult });

        // notifyCompletionCallbacks is async — flush microtasks
        await Promise.resolve();

        expect(results).toHaveLength(1);
        expect(results[0]).toBe(taskResult);
    });

    test('incoming task-message IPC message triggers onTaskMessage and onAnyTaskMessage callbacks', async () => {
        const api = makeElectronAPI();
        const backend = new ElectronRendererQueueBackend(api as any);
        const typedMessages: any[] = [];
        const anyMessages: any[] = [];
        backend.onTaskMessage('progress', (data) => { typedMessages.push(data); });
        backend.onAnyTaskMessage((data) => { anyMessages.push(data); });

        api._emit('task-message', { taskId: 'task-1', message: { type: 'progress', value: 50 } });

        await Promise.resolve();

        expect(typedMessages).toHaveLength(1);
        expect(anyMessages).toHaveLength(1);
    });

    test('cancelTasks sends the correct cancel IPC message', () => {
        const api = makeElectronAPI();
        const backend = new ElectronRendererQueueBackend(api as any);

        backend.cancelTasks('my-source');

        expect(api.cancelTasks).toHaveBeenCalledWith('my-source');
    });

    test('unsubscribe functions remove only their registered callback', async () => {
        const api = makeElectronAPI();
        const backend = new ElectronRendererQueueBackend(api as any);
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
        api._emit('task-completed', { taskId: 'task-1', result: taskResult });
        await Promise.resolve();

        expect(firedA).toHaveLength(0);
        expect(firedB).toHaveLength(1);
    });
});
