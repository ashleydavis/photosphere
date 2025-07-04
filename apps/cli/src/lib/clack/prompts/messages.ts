import type { Writable } from 'node:stream';
import color from 'picocolors';
import { type CommonOptions, S_BAR_END } from './common';

export const cancel = (message = '', opts?: CommonOptions) => {
	const output: Writable = opts?.output ?? process.stdout;
	output.write(`${color.gray(S_BAR_END)}  ${color.red(message)}\n\n`);
};

export const intro = (title = '', opts?: CommonOptions) => {
	const output: Writable = opts?.output ?? process.stdout;
	output.write(`\n${title}\n`);
};

export const outro = (message = '', opts?: CommonOptions) => {
	const output: Writable = opts?.output ?? process.stdout;
	output.write(`\n${message}\n\n`);
};
