//
// Port of the local copy of @clack/prompts (src/lib/clack/prompts/index.ts): the prompts used by the CLI.
// Every prompt takes the caller's allocator (an arena) and io, and returns PromptResult(T): the value or
// cancel (TypeScript: the value or the cancel symbol, tested with isCancel).
//
const core = @import("core/index.zig");
pub const isCancel = core.isCancel;
pub const PromptResult = core.PromptResult;
pub const settings = core.settings;
pub const common = @import("prompts/common.zig");
pub const CommonOptions = common.CommonOptions;
pub const confirm_module = @import("prompts/confirm.zig");
pub const confirm = confirm_module.confirm;
pub const ConfirmOptions = confirm_module.ConfirmOptions;
pub const limit_options = @import("prompts/limit-options.zig");
pub const limitOptions = limit_options.limitOptions;
pub const messages = @import("prompts/messages.zig");
pub const cancel = messages.cancel;
pub const intro = messages.intro;
pub const outro = messages.outro;
pub const multiline_module = @import("prompts/multiline.zig");
pub const multiline = multiline_module.multiline;
pub const MultilineOptions = multiline_module.MultilineOptions;
pub const password_module = @import("prompts/password.zig");
pub const password = password_module.password;
pub const PasswordOptions = password_module.PasswordOptions;
pub const select_module = @import("prompts/select.zig");
pub const select = select_module.select;
pub const SelectOptions = select_module.SelectOptions;
pub const Option = select_module.Option;
pub const text_module = @import("prompts/text.zig");
pub const text = text_module.text;
pub const TextOptions = text_module.TextOptions;
pub const ValidateFn = @import("core/prompts/prompt.zig").ValidateFn;
pub const MultilineValidateFn = @import("core/prompts/multiline.zig").MultilineValidateFn;
pub const PromptInput = @import("third-party/readline.zig").PromptInput;
// Not ported: autocomplete, group-multi-select, group, log, multi-select, note, path, progress-bar,
// select-key, spinner, stream, task, task-log (not used by replicate or verify).
