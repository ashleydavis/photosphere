//
// Exit codes for process termination.
// Use distinct values so scripts can distinguish failure modes.
//

//
// Process completed successfully.
//
pub const EXIT_SUCCESS: u8 = 0;

//
// General command failure (e.g. validation, business logic).
//
pub const EXIT_FAILURE: u8 = 1;

// Custom exit codes start at 64 to avoid colliding with shell/signal conventions (e.g. 2 = misuse, 128+ = signal).

//
// Process terminated due to uncaught exception.
//
pub const EXIT_UNCAUGHT_EXCEPTION: u8 = 64;

//
// Process terminated due to unhandled promise rejection.
//
pub const EXIT_UNHANDLED_REJECTION: u8 = 65;

//
// exit() was called but termination callbacks threw.
//
pub const EXIT_TERMINATION_CALLBACKS_THREW: u8 = 66;

//
// SIGTERM received but termination callbacks threw.
//
pub const EXIT_SIGTERM_CLEANUP_FAILED: u8 = 67;

//
// SIGINT received (e.g. Ctrl+C) but termination callbacks threw.
//
pub const EXIT_SIGINT_CLEANUP_FAILED: u8 = 68;

//
// Uncaught exception and termination callbacks threw.
//
pub const EXIT_UNCAUGHT_EXCEPTION_CLEANUP_FAILED: u8 = 69;

//
// Unhandled rejection and termination callbacks threw.
//
pub const EXIT_UNHANDLED_REJECTION_CLEANUP_FAILED: u8 = 70;
