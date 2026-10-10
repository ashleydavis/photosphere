import { answerTestCommand, createZiggyTestTransport, signalTestPageReady, testCommandResultToJson, toLogLevel, type ITestCommandBody } from '../lib/ziggy-test-transport';
import { FakeZiggy } from './fake-ziggy';
import type { ITestCommandPayload } from 'user-interface';

//
// A command the driver stand-in was given.
//
interface ISeenCommand {
    // The command name.
    command: string;

    // The arguments it came with.
    payload: ITestCommandPayload;
}

describe('answerTestCommand', () => {
    test('ready is answered without asking the driver', async () => {
        let asked = false;

        const result = await answerTestCommand(async () => {
            asked = true;
            return undefined;
        }, { command: 'ready' });

        expect(result).toEqual({ ok: true });
        expect(asked).toBe(false);
    });

    test('hands the command and its arguments to the driver', async () => {
        const seen: ISeenCommand[] = [];

        const result = await answerTestCommand(async (command, payload) => {
            seen.push({ command, payload });
            return undefined;
        }, { command: 'type', dataId: 'name-input', text: 'hello' });

        expect(result).toEqual({ ok: true });
        expect(seen).toHaveLength(1);
        expect(seen[0].command).toBe('type');
        expect(seen[0].payload).toMatchObject({ dataId: 'name-input', text: 'hello' });
    });

    test('a value from the driver is the value of the result', async () => {
        const result = await answerTestCommand(async () => 'the text', { command: 'get-value', dataId: 'x' });

        expect(result).toEqual({ ok: true, value: 'the text' });
    });

    test('an empty value is still a value', async () => {
        const result = await answerTestCommand(async () => '', { command: 'get-value', dataId: 'x' });

        expect(result).toEqual({ ok: true, value: '' });
    });

    test('a command the driver rejects is a failure with its reason', async () => {
        const result = await answerTestCommand(async (command) => {
            throw new Error(`Test command not implemented on this platform: ${command}`);
        }, { command: 'frobnicate' });

        expect(result).toEqual({ ok: false, error: 'Test command not implemented on this platform: frobnicate' });
    });

    test('stage-export reaches the driver with its outcome', async () => {
        const seen: { command: string; exportOutcome?: string }[] = [];

        const result = await answerTestCommand(async (command, payload) => {
            seen.push({
                command,
                exportOutcome: payload.exportOutcome,
            });
            return undefined;
        }, { command: 'stage-export', exportOutcome: 'shared' });

        expect(result).toEqual({ ok: true });
        expect(seen).toEqual([{ command: 'stage-export', exportOutcome: 'shared' }]);
    });

    test('a command that cannot work on Ziggy fails without reaching the driver', async () => {
        for (const command of ['pick-files', 'stage-pick-folder', 'stage-delete']) {
            let asked = false;

            const result = await answerTestCommand(async () => {
                asked = true;
                return undefined;
            }, { command });

            expect(asked).toBe(false);
            expect(result.ok).toBe(false);
            expect(result.error).toBeDefined();
        }
    });
});

describe('testCommandResultToJson', () => {
    test('leaves out the fields with no value', () => {
        expect(testCommandResultToJson({ ok: true })).toEqual({ ok: true });
    });

    test('keeps the value and the error', () => {
        expect(testCommandResultToJson({ ok: true, value: 'v' })).toEqual({ ok: true, value: 'v' });
        expect(testCommandResultToJson({ ok: false, error: 'e' })).toEqual({ ok: false, error: 'e' });
    });
});

describe('toLogLevel', () => {
    test('passes the levels the core knows', () => {
        for (const level of ['info', 'verbose', 'error', 'exception', 'warn', 'debug', 'tool', 'event']) {
            expect(toLogLevel(level)).toBe(level);
        }
    });

    test('throws for a level it does not know', () => {
        expect(() => toLogLevel('trace')).toThrow('"trace"');
    });
});

describe('createZiggyTestTransport', () => {
    test('answers each test-command event on the test-result channel with its request id', async () => {
        const ziggy = new FakeZiggy();
        ziggy.replies.set('test-result', null);
        const transport = createZiggyTestTransport(ziggy);
        transport.onCommand(async (command) => (command === 'get-value' ? 'hello' : undefined));
        const body: ITestCommandBody = { command: 'get-value', dataId: 'x' };

        ziggy.emit('test-command', { requestId: 7, command: body as any });
        await new Promise(resolve => setTimeout(resolve, 0));

        expect(ziggy.invoked).toEqual([
            { channel: 'test-result', data: { requestId: 7, result: { ok: true, value: 'hello' } } },
        ]);
    });

    test('forwards the driver log lines to the renderer-log channel', () => {
        const ziggy = new FakeZiggy();
        const transport = createZiggyTestTransport(ziggy);

        transport.sendLog('warn', 'careful');

        expect(ziggy.sent).toEqual([{ channel: 'renderer-log', data: { level: 'warn', message: 'careful' } }]);
    });
});

describe('signalTestPageReady', () => {
    test('sends test-page-ready', () => {
        const ziggy = new FakeZiggy();

        signalTestPageReady(ziggy);

        expect(ziggy.sent).toEqual([{ channel: 'test-page-ready', data: null }]);
    });
});
