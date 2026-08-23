import type { ITaskContext } from 'task-queue';
import type { IReceiveShareTaskData, IFindReceiverTaskData, ISendPayloadTaskData, IShareReceiverEndpoint } from 'api';

// ── module mock ────────────────────────────────────────────────────────────────
//
// Substitute fake LanShareReceiver / LanShareSender classes so no real UDP/HTTPS
// sockets are opened. Created instances are captured in mock-prefixed arrays so
// tests can drive their behaviour and assert on the calls they received.
//

const mockReceivers: any[] = [];
const mockSenders: any[] = [];
const mockSendResultRef = { value: true };

jest.mock('lan-share-network', () => {
    //
    // Fake receiver whose receive() stays pending until a payload is delivered or cancel() is called.
    //
    class FakeLanShareReceiver {
        timeoutMs: number;
        startCode: string | undefined;
        cancelled: boolean;
        cancelCount: number;
        resolveReceive: ((payload: any) => void) | undefined;

        constructor(timeoutMs: number) {
            this.timeoutMs = timeoutMs;
            this.startCode = undefined;
            this.cancelled = false;
            this.cancelCount = 0;
            this.resolveReceive = undefined;
            mockReceivers.push(this);
        }

        async start(code: string): Promise<void> {
            this.startCode = code;
        }

        receive(): Promise<any> {
            return new Promise(resolve => {
                this.resolveReceive = resolve;
            });
        }

        cancel(): void {
            this.cancelled = true;
            this.cancelCount++;
            if (this.resolveReceive) {
                this.resolveReceive(null);
                this.resolveReceive = undefined;
            }
        }
    }

    //
    // Fake sender whose waitForReceiver() stays pending until an endpoint is delivered or cancel() is called.
    //
    class FakeLanShareSender {
        payload: any;
        code: string;
        cancelled: boolean;
        cancelCount: number;
        sentEndpoint: any;
        resolveWait: ((endpoint: any) => void) | undefined;

        constructor(payload: any, code: string) {
            this.payload = payload;
            this.code = code;
            this.cancelled = false;
            this.cancelCount = 0;
            this.sentEndpoint = undefined;
            this.resolveWait = undefined;
            mockSenders.push(this);
        }

        waitForReceiver(_timeoutMs: number): Promise<any> {
            return new Promise(resolve => {
                this.resolveWait = resolve;
            });
        }

        cancel(): void {
            this.cancelled = true;
            this.cancelCount++;
            if (this.resolveWait) {
                this.resolveWait(null);
                this.resolveWait = undefined;
            }
        }

        async send(endpoint: any): Promise<boolean> {
            this.sentEndpoint = endpoint;
            return mockSendResultRef.value;
        }
    }

    return {
        LanShareReceiver: FakeLanShareReceiver,
        LanShareSender: FakeLanShareSender,
    };
});

// ── imports after mock ───────────────────────────────────────────────────────

import { receiveShareHandler, findReceiverHandler, sendPayloadHandler } from '../../lib/lan-share.worker';

// ── helpers ───────────────────────────────────────────────────────────────────

//
// Builds a minimal ITaskContext for testing, with a controllable isCancelled.
//
function makeContext(isCancelled: boolean = false): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue('test-uuid') },
        timestampProvider: { now: jest.fn().mockReturnValue(0), dateNow: jest.fn().mockReturnValue(new Date(0)) },
        sessionId: 'session-1',
        maxConcurrentChildTasks: 10,
        taskId: 'task-1',
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(isCancelled),
    };
}

//
// Flushes pending microtasks so awaited handler steps make progress under both real and fake timers.
//
async function flushMicrotasks(): Promise<void> {
    for (let index = 0; index < 5; index++) {
        await Promise.resolve();
    }
}

//
// A sample discovered endpoint used by the find/send tests.
//
const sampleEndpoint: IShareReceiverEndpoint = {
    address: '192.168.0.5',
    port: 4321,
    certFingerprint: 'aabbccdd',
};

// ── tests ────────────────────────────────────────────────────────────────────

describe('receiveShareHandler', () => {
    beforeEach(() => {
        mockReceivers.length = 0;
        mockSenders.length = 0;
        mockSendResultRef.value = true;
    });

    afterEach(() => {
        jest.useRealTimers();
    });

    test('calls receiver.start with the supplied code and returns the delivered payload', async () => {
        const context = makeContext();
        const data: IReceiveShareTaskData = { code: '4242' };
        const payload = { type: 'secret', name: 'aws', secretType: 's3-credentials', value: '{}' };

        const promise = receiveShareHandler(data, context);
        await flushMicrotasks();

        const receiver = mockReceivers[0];
        expect(receiver.startCode).toBe('4242');

        receiver.resolveReceive(payload);
        const result = await promise;

        expect(result).toEqual({ payload });
    });

    test('returns { payload: null } when receive resolves null (timeout)', async () => {
        const context = makeContext();
        const promise = receiveShareHandler({ code: '1111' }, context);
        await flushMicrotasks();

        const receiver = mockReceivers[0];
        receiver.resolveReceive(null);
        const result = await promise;

        expect(result).toEqual({ payload: null });
    });

    test('cancels the receiver when the context reports cancellation and clears the interval afterwards', async () => {
        jest.useFakeTimers();
        const context = makeContext(true);

        const promise = receiveShareHandler({ code: '2222' }, context);
        await flushMicrotasks();

        const receiver = mockReceivers[0];
        expect(receiver.resolveReceive).toBeDefined();

        // Advance past the cancel poll interval so the watcher fires.
        jest.advanceTimersByTime(300);
        await flushMicrotasks();

        const result = await promise;
        expect(receiver.cancelled).toBe(true);
        expect(result).toEqual({ payload: null });

        // The interval must have been cleared in the finally block: advancing again does not cancel again.
        jest.advanceTimersByTime(1000);
        expect(receiver.cancelCount).toBe(1);
    });
});

describe('findReceiverHandler', () => {
    beforeEach(() => {
        mockReceivers.length = 0;
        mockSenders.length = 0;
        mockSendResultRef.value = true;
    });

    afterEach(() => {
        jest.useRealTimers();
    });

    test('constructs the sender with the code and returns the discovered endpoint', async () => {
        const context = makeContext();
        const data: IFindReceiverTaskData = { code: '3333' };

        const promise = findReceiverHandler(data, context);
        await flushMicrotasks();

        const sender = mockSenders[0];
        expect(sender.code).toBe('3333');
        expect(sender.payload).toBeUndefined();

        sender.resolveWait(sampleEndpoint);
        const result = await promise;

        expect(result).toEqual({ endpoint: sampleEndpoint });
    });

    test('returns { endpoint: null } on timeout', async () => {
        const context = makeContext();
        const promise = findReceiverHandler({ code: '4444' }, context);
        await flushMicrotasks();

        const sender = mockSenders[0];
        sender.resolveWait(null);
        const result = await promise;

        expect(result).toEqual({ endpoint: null });
    });

    test('cancels the sender when the context reports cancellation', async () => {
        jest.useFakeTimers();
        const context = makeContext(true);

        const promise = findReceiverHandler({ code: '5555' }, context);
        await flushMicrotasks();

        const sender = mockSenders[0];
        jest.advanceTimersByTime(300);
        await flushMicrotasks();

        const result = await promise;
        expect(sender.cancelled).toBe(true);
        expect(result).toEqual({ endpoint: null });
    });
});

describe('sendPayloadHandler', () => {
    beforeEach(() => {
        mockReceivers.length = 0;
        mockSenders.length = 0;
        mockSendResultRef.value = true;
    });

    test('constructs the sender with payload/code, calls send with the endpoint, and returns success true', async () => {
        const payload = { type: 'database', name: 'db', description: '', path: '/db' } as any;
        const data: ISendPayloadTaskData = { payload, code: '6666', endpoint: sampleEndpoint };
        mockSendResultRef.value = true;

        const result = await sendPayloadHandler(data);

        const sender = mockSenders[0];
        expect(sender.payload).toBe(payload);
        expect(sender.code).toBe('6666');
        expect(sender.sentEndpoint).toBe(sampleEndpoint);
        expect(result).toEqual({ success: true });
    });

    test('returns success false when the receiver rejects the payload', async () => {
        const payload = { type: 'secret', name: 's', secretType: 'api-key', value: '{}' } as any;
        const data: ISendPayloadTaskData = { payload, code: '7777', endpoint: sampleEndpoint };
        mockSendResultRef.value = false;

        const result = await sendPayloadHandler(data);

        expect(result).toEqual({ success: false });
    });
});
