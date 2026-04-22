import { MultilinePrompt } from '../core/index';
import color from 'picocolors';
import { type CommonOptions, S_BAR, S_BAR_END, symbol } from './common';

//
// Options for the multiline() prompt.
//
export interface MultilineOptions extends CommonOptions {
    //
    // Label shown above the input area.
    //
    message: string;

    //
    // Optional validation run when the user presses Ctrl+D.
    // Return a string or Error to block submission and show an error.
    //
    validate?: (value: string) => string | Error | undefined;
}

//
// Renders a multiline text input prompt.
// Enter adds a new line; Ctrl+D submits; Ctrl+C cancels.
//
export const multiline = (opts: MultilineOptions) => {
    return new MultilinePrompt({
        validate: opts.validate,
        signal: opts.signal,
        input: opts.input,
        output: opts.output,
        render() {
            const title = `${symbol(this.state)}  ${opts.message}\n`;
            const allLines = [...this.completedLines, this.currentLine];

            switch (this.state) {
                case 'error': {
                    const linesText = allLines
                        .map(line => `${color.yellow(S_BAR)}  ${line}`)
                        .join('\n');
                    return `${title.trim()}\n${linesText}\n${color.yellow(S_BAR_END)}  ${color.yellow(this.error)}\n`;
                }
                case 'submit': {
                    const lineCount = [...this.completedLines, this.currentLine]
                        .filter(line => line.length > 0).length;
                    const summary = `${lineCount} line${lineCount === 1 ? '' : 's'}`;
                    return `${title}${color.gray(S_BAR)}  ${color.dim(summary)}`;
                }
                case 'cancel': {
                    return `${title}${color.gray(S_BAR)}`;
                }
                default: {
                    const linesText = allLines
                        .map((line, lineIndex) => {
                            const isCurrentLine = lineIndex === allLines.length - 1;
                            if (isCurrentLine) {
                                const before = line.slice(0, this.cursorPos);
                                const atCursor = line[this.cursorPos] ?? '';
                                const after = line.slice(this.cursorPos + 1);
                                const cursorChar = atCursor
                                    ? color.inverse(atCursor)
                                    : color.inverse(color.hidden('_'));
                                return `${color.cyan(S_BAR)}  ${before}${cursorChar}${after}`;
                            }
                            return `${color.cyan(S_BAR)}  ${line}`;
                        })
                        .join('\n');
                    return `${title}${linesText}\n${color.cyan(S_BAR_END)}  ${color.dim('Ctrl+D to submit')}\n`;
                }
            }
        },
    }).prompt() as Promise<string | symbol>;
};
