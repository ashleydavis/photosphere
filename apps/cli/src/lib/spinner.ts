import { log } from 'utils';
import { spinner as clackSpinner } from './clack/prompts';
import type { SpinnerResult } from './clack/prompts';

//
// Returns something to report the progress of a long wait with, matched to whether anyone is
// watching it happen.
//
// An interactive run gets the animated spinner. A non-interactive run (`--yes`) gets plain log lines
// saying the same things, because the spinner is not just decoration: it takes hold of the terminal
// to swallow the keystrokes of the person watching it, and switching the terminal into raw mode from
// outside its foreground process group is a thing the kernel stops a process for. Nothing resumes it.
//
// That is not hypothetical. Every CLI smoke test runs under `timeout`, which puts it in a process
// group of its own, so `psi dbs send --yes` started spinning and froze on the spot, silent, until the
// suite's 300 second timeout killed it. It only happened with a terminal attached, so the git hook
// and CI never saw it.
//
// Usage: spinner(!skipPrompts)
//
export function spinner(interactive: boolean): SpinnerResult {
    if (interactive) {
        return clackSpinner();
    }

    return {
        start(message: string = ''): void {
            log.info(message);
        },
        stop(message: string = ''): void {
            log.info(message);
        },
        message(message: string = ''): void {
            log.info(message);
        },

        // The animated spinner sets this when a signal arrives mid-spin, which it can only know
        // about because it is the thing holding the terminal. Nothing here holds anything, and every
        // caller installs its own SIGINT handler, so there is nothing for this to report.
        get isCancelled(): boolean {
            return false;
        },
    };
}
