import type { Writable } from 'node:stream';
import { stripVTControlCharacters as strip } from 'node:util';
import color from 'picocolors';
import {
	type CommonOptions,
	S_BAR,
	S_BAR_H,
	S_CONNECT_LEFT,
	S_CORNER_BOTTOM_RIGHT,
} from './common';

export interface NoteOptions extends CommonOptions {
	format?: (line: string) => string;
}

const defaultNoteFormatter = (line: string): string => color.dim(line);

export const note = (message = '', title = '', opts?: NoteOptions) => {
	const format = opts?.format ?? defaultNoteFormatter;
	const lines = ['', ...message.split('\n').map(format), ''];
	const titleLen = strip(title).length;
	const output: Writable = opts?.output ?? process.stdout;
	const len =
		Math.max(
			lines.reduce((sum, ln) => {
				const line = strip(ln);
				return line.length > sum ? line.length : sum;
			}, 0),
			titleLen
		) + 2;
	const msg = lines
		.map(
			(ln) => `${color.gray(S_BAR)}  ${ln}${' '.repeat(len - strip(ln).length)}${color.gray(S_BAR)}`
		)
		.join('\n');
	if (title) {
		output.write(`   ${color.reset(title)}\n${msg}\n`);
	}
	else {
		output.write(`   ${msg}\n`);
	}
};
