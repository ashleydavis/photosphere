import { stdin, stdout } from 'node:process';
import * as readline from 'node:readline';
import type { Key } from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import { cursor, erase } from 'sisteransi';
import wrap from 'wrap-ansi';
import { CANCEL_SYMBOL, isActionKey, setRawMode } from '../utils/index';
import type { ClackState } from '../types';

//
// Options accepted by MultilinePrompt.
//
export interface MultilinePromptOptions<Self extends MultilinePrompt> {
    //
    // Returns the frame string to render for the current state.
    //
    render(this: Omit<Self, 'prompt'>): string | undefined;

    //
    // Optional validation run on Ctrl+D. Return a string or Error to block submission.
    //
    validate?: (value: string) => string | Error | undefined;

    //
    // Input stream (defaults to process.stdin).
    //
    input?: Readable;

    //
    // Output stream (defaults to process.stdout).
    //
    output?: Writable;

    //
    // AbortSignal that cancels the prompt programmatically.
    //
    signal?: AbortSignal;
}

//
// A multiline text input prompt.
// Enter adds a new line; Ctrl+D submits; Ctrl+C cancels.
//
export class MultilinePrompt {
    //
    // Input stream used for reading keypresses.
    //
    protected input: Readable;

    //
    // Output stream used for rendering.
    //
    protected output: Writable;

    //
    // Lines that have been completed by pressing Enter.
    //
    public completedLines: string[] = [];

    //
    // The line currently being typed.
    //
    public currentLine: string = '';

    //
    // Cursor position within the current line.
    //
    public cursorPos: number = 0;

    //
    // Current prompt state.
    //
    public state: ClackState = 'initial';

    //
    // Validation error message, populated when validation fails on submit.
    //
    public error: string = '';

    private _validate?: (value: string) => string | Error | undefined;
    private _render: (context: Omit<MultilinePrompt, 'prompt'>) => string | undefined;
    private _prevFrame: string = '';
    private _abortSignal?: AbortSignal;
    private _rl?: readline.Interface;

    constructor(opts: MultilinePromptOptions<MultilinePrompt>) {
        this.input = opts.input ?? stdin;
        this.output = opts.output ?? stdout;
        this._validate = opts.validate;
        this._render = opts.render.bind(this);
        this._abortSignal = opts.signal;
    }

    //
    // Returns the full accumulated text: completed lines joined with newlines,
    // followed by the current line.
    //
    public getValue(): string {
        return [...this.completedLines, this.currentLine].join('\n');
    }

    private onKeypress(char: string | undefined, key: Key): void {
        if (this.state === 'error') {
            this.state = 'active';
        }

        if ((key.ctrl && key.name === 'd') || char === '\x04') {
            const value = this.getValue();
            if (this._validate) {
                const problem = this._validate(value);
                if (problem) {
                    this.error = problem instanceof Error ? problem.message : problem;
                    this.state = 'error';
                }
                else {
                    this.state = 'submit';
                }
            }
            else {
                this.state = 'submit';
            }
        }
        else if (isActionKey([char, key?.name, key?.sequence], 'cancel')) {
            this.state = 'cancel';
        }
        else if (key.name === 'return') {
            this.completedLines.push(this.currentLine);
            this.currentLine = '';
            this.cursorPos = 0;
        }
        else if (key.name === 'backspace') {
            if (this.cursorPos > 0) {
                this.currentLine =
                    this.currentLine.slice(0, this.cursorPos - 1) +
                    this.currentLine.slice(this.cursorPos);
                this.cursorPos--;
            }
            else if (this.completedLines.length > 0) {
                const prevLine = this.completedLines.pop() ?? '';
                this.cursorPos = prevLine.length;
                this.currentLine = prevLine + this.currentLine;
            }
        }
        else if (char && !key.ctrl && !key.meta && char.length === 1) {
            this.currentLine =
                this.currentLine.slice(0, this.cursorPos) +
                char +
                this.currentLine.slice(this.cursorPos);
            this.cursorPos++;
        }

        this.render();
    }

    private render(): void {
        const frame = wrap(this._render(this) ?? '', process.stdout.columns, { hard: true, trim: false });
        if (frame === this._prevFrame) {
            return;
        }

        if (this.state === 'initial') {
            this.output.write(cursor.hide);
        }
        else {
            const prevLineCount = wrap(this._prevFrame, process.stdout.columns, { hard: true, trim: false })
                .split('\n').length - 1;
            this.output.write(cursor.move(-999, -prevLineCount));
            this.output.write(erase.down());
        }

        this.output.write(frame);

        if (this.state === 'initial') {
            this.state = 'active';
        }

        this._prevFrame = frame;
    }

    private close(): void {
        this.output.write(cursor.show);
        this.output.write('\n');
        setRawMode(this.input, false);
        this._rl?.close();
        this._rl = undefined;
    }

    //
    // Displays the prompt and resolves with the entered text on submit,
    // or with CANCEL_SYMBOL if the user cancels.
    //
    public prompt(): Promise<string | symbol> {
        return new Promise<string | symbol>((resolve) => {
            if (this._abortSignal?.aborted) {
                this.state = 'cancel';
                this.render();
                this.close();
                resolve(CANCEL_SYMBOL);
                return;
            }

            if (this._abortSignal) {
                this._abortSignal.addEventListener('abort', () => {
                    this.state = 'cancel';
                    this.render();
                    this.close();
                    resolve(CANCEL_SYMBOL);
                }, { once: true });
            }

            this._rl = readline.createInterface({
                input: this.input,
                terminal: true,
                prompt: '',
            });
            readline.emitKeypressEvents(this.input, this._rl);
            setRawMode(this.input, true);

            const resizeHandler = () => this.render();
            this.output.on('resize', resizeHandler);

            this.render();

            const keypressHandler = (char: string | undefined, key: Key) => {
                this.onKeypress(char, key);
                if (this.state === 'submit') {
                    this.input.removeListener('keypress', keypressHandler);
                    this.output.off('resize', resizeHandler);
                    this.close();
                    resolve(this.getValue());
                }
                else if (this.state === 'cancel') {
                    this.input.removeListener('keypress', keypressHandler);
                    this.output.off('resize', resizeHandler);
                    this.close();
                    resolve(CANCEL_SYMBOL);
                }
            };

            this.input.on('keypress', keypressHandler);
        });
    }
}
