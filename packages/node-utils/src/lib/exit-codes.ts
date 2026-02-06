//
// Exit codes for process termination.
// Use distinct values so scripts can distinguish failure modes.
//

/** Process completed successfully. */
export const EXIT_SUCCESS = 0;

/** General command failure (e.g. validation, business logic). */
export const EXIT_FAILURE = 1;

/** Custom exit codes start at 64 to avoid colliding with shell/signal conventions (e.g. 2 = misuse, 128+ = signal). */

/** Process terminated due to uncaught exception. */
export const EXIT_UNCAUGHT_EXCEPTION = 64;

/** Process terminated due to unhandled promise rejection. */
export const EXIT_UNHANDLED_REJECTION = 65;

/** exit() was called but termination callbacks threw. */
export const EXIT_TERMINATION_CALLBACKS_THREW = 66;

/** SIGTERM received but termination callbacks threw. */
export const EXIT_SIGTERM_CLEANUP_FAILED = 67;

/** SIGINT received (e.g. Ctrl+C) but termination callbacks threw. */
export const EXIT_SIGINT_CLEANUP_FAILED = 68;

/** Uncaught exception and termination callbacks threw. */
export const EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED = 69;

/** Unhandled rejection and termination callbacks threw. */
export const EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED = 70;
