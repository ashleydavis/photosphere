//
// The state of the prompt
//
pub const ClackState = enum {
    // The prompt has not been rendered yet.
    initial,

    // The prompt is waiting for input.
    active,

    // The prompt was cancelled.
    cancel,

    // The prompt was submitted.
    submit,

    // The input failed validation.
    @"error",
};

// Not ported: ClackEvents (Zig prompts call their event handlers directly).
