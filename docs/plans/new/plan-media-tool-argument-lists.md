# Pass argument lists to the built-in media tools

## Overview

A file whose path contains `$`, a backtick or `"` cannot be imported. `tools-zig` builds shell-style command strings for ImageMagick, ffmpeg and ffprobe with each path inside double quotes and no escaping (`magick "<path>" -resize ...`). `exec` hands the string to `in-process-tools.zig`, where `splitCommand` parses it back into words. `splitCommand` throws on `$` and backtick inside double quotes, and a `"` in a path ends the quoted word early. The runner the string ends up at (`InProcessRunner.run`) already takes the tool and an argument list. This plan first writes tests that import such files and watches them fail, then makes `tools-zig` build the argument list itself and call the runner through two new functions, `runTool` and `runToolLogged`, so no command string is built or parsed for the tools. It then removes `splitCommand`, `tryRun`, the `handles` field of `InProcessRunner` and node-utils' own copies of `exec` and `execLogged`, which become re-exports of Ziggy's. Finally it removes the bug from `docs/investigations/media-tools-review.md` and updates the parts of that doc and `docs/mobile-native-media.md` that describe the string flow.

## Issues

1. [x] Every build and test command pipes through `tee tmp/<name>.log`. The global rules say a command the agent runs itself is run as it is, with no `tee` and no log file. The logs are also left behind, and there is no Clean up step to remove them.
2. [x] The new real-tool unit tests (step 2) and smoke test 139 (step 4) are only written and run after the fix. No step runs them against the current code to show they fail on `$`, a backtick and `"`. As planned, they have never been seen to catch the bug.
3. [x] Step 5 has `docs/mobile-native-media.md` say "a path may hold any character its file system allows". Nobody checked this. ImageMagick reads `[...]`, `*`, `?` and a `format:` prefix in file names. ImageMagick and ffmpeg both read `%d` patterns in output names, and ffmpeg reads a `protocol:` prefix in input names. None of these characters are tested.
4. [x] Smoke test 139 checks "Files added", "Files failed", the summary count and `verify_database`. Its `test.md` says the files are imported "with their thumbnails", but nothing checks for a thumbnail. The plan also does not check whether a failed thumbnail or screenshot would make `Files failed` non-zero.
5. [x] After step 3, `exec`/`execLogged` in `node-utils-zig/src/lib/exec.zig` become copies of Ziggy's `exec.exec` and `exec.execLogged`, which have the same signatures (`ziggy/core/src/lib/exec.zig:31,594`). The plan keeps the wrapper and never considers calling Ziggy's directly.
6. [x] The real-tool test in `image.test.zig` says "`resize` to `jpg`" without saying whether `options.format` is set. The `"<format>:<outputPath1>"` single-element branch may never run with an odd output path.
7. [x] Step 3 says to "drop the `log, null` / `null` arguments" in `exec.test.zig`. The `execLogged` calls there have two `null` arguments (tools and validate), and the plan does not say which one goes.
8. [x] The new unit tests do not check the `Executing {tool} with command: "{description}"` verbose log line or the `Validation failed for command:` log text from `runToolLogged`. Step 1 says both must match `execLogged` exactly.
9. [x] The new `video.info.test.zig` test checks the odd-named copy with `expectTestMp4Info`, but that helper asserts `info.filePath` equals `"../test/multiple-files/test.mp4"` (`video.info.test.zig:48`). The copy has a different path, so this test fails after the fix as well as before it, and step 3's "must exit 0" can never pass.
10. [x] In smoke test 139, the asset ids are read with `grep -o 'to the database with ID "[^"]*"\.$'`, which needs the line to end in `.`. Test 105 reads the same line without a `$` anchor. The plan never checked that the captured output ends that line with nothing after the `.`, such as a `\r` on Windows or a colour code.
11. [x] The `image.test.zig` resize options are described as "the options `node-api-zig/src/lib/image.zig:410` passes in production". Production passes a computed width and height and a rounded quality (`.width = width, .height = height, .quality = jsRound(quality)`). Only `.format = "jpeg"` and `.ext = "jpg"` match `.{ .width = 100, .height = 0, .quality = 90, ... }`.
12. [x] Step 5 says the `ThreadTools` sentence in `docs/investigations/media-tools-review.md` is on line 60. It is on line 59.
13. [x] Verify's full-set check depended on something outside the agent's reach. Resolved: the human ruled that no plan mentions that, and Verify runs plain `bun run test:everything`.
14. [x] Verify's full-set check told the agent what it cannot do. Resolved: that text is gone.
15. [x] Verify ran a named subset of `test:everything` as the full check, which the project `CLAUDE.md` forbids. Resolved: Verify runs plain `bun run test:everything`.

## Steps

Every command below is run from the repository root, as it is, and its output is read from the tool result. No command is piped to `tee` or redirected to a file.

1. **Write the tests for odd file names and watch them fail on the current code.** These tests use only the existing API (`Image`, `Video`, `heic`, `MediaTools.runner()`), so they compile before any production change.
    - Add the three real-tool tests listed under "Unit Tests, written in step 1" to `packages-zig/tools-zig/src/test/image.test.zig`, `video.info.test.zig` and `heic.test.zig`.
    - Create `apps/cli-zig/smoke-tests-zig/139-odd-file-names/test.sh` and `test.md` as described under Smoke Tests.
    - Run `mise exec -- zig build test -Dtest-file=tools-zig/image.test.zig -Dtest-file=tools-zig/video.info.test.zig -Dtest-file=tools-zig/heic.test.zig`. It must exit non-zero, with exactly the three new tests failing and every other test in those files passing. The failures must come from the tools: `The command uses shell syntax that cannot run in the app's process` for `$` and backtick, or a tool failing to read a file for `"`. A new test that passes here does not catch the bug: rewrite it until it fails for that reason.
    - Run `mise exec -- bun run test:cli:zig -- 139`. It must exit non-zero, with the failure in the add or thumbnail checks of the odd-named files. A run that passes here means the test does not catch the bug: rewrite it until it fails for that reason.
    - Nothing in this step changes production code.

2. **Add `runTool` and `runToolLogged` to `packages-zig/node-utils-zig/src/lib/in-process-tools.zig`.** Keep everything that is there for now.
    - `pub fn runTool(allocator: std.mem.Allocator, io: std.Io, log: ILog, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8) !exec.ExecResult`
        - Calls `runner.run(runner.context, io, log, allocator, tool, arguments)`.
        - When `exit_code != 0`, throws `errors.throwError("Command failed: {s}\n{s}", .{ <description>, result.output })`, where `<description>` is the tool followed by each argument, separated by single spaces. This is the same text `tryRun` throws today (`tools-zig/src/test/image.command.test.zig:113` and `video.probe.test.zig:195,200` assert `"Command failed: magick -version\n"` through the verify functions, and must keep passing unchanged).
        - Returns `.{ .stdout = result.output, .stderr = "" }`, as `tryRun` does.
    - `pub fn runToolLogged(allocator: std.mem.Allocator, io: std.Io, log: ILog, runner: InProcessRunner, tool: []const u8, arguments: []const []const u8, validate: ?exec.IValidate) !exec.ExecResult`
        - The argument-list twin of `execLogged`, with the same messages built from the description: logs `Executing {tool} with command: "{description}"` at verbose, calls `runTool`, passes the output to `log.tool(tool, .{ .stdout = result.stdout, .stderr = result.stderr })`, runs `validate` and on its failure logs `Validation failed for command: {description}\nReason: {reason}` as an error and the `===\nCommand: ...` block as info, then throws, exactly as `execLoggedInner` does. Any failure is wrapped as `Failed to execute command: {description}` after `log.exception` (`tools-zig/src/test/image.test.zig:447,467,488,513` look for that text in the log).
        - Put the try-block body in a private `runToolLoggedInner`, the way `execLogged` has `execLoggedInner`.
    - Add a private helper `describeCommand(allocator, tool, arguments) ![]const u8` that builds the description. Its doc comment says the text is only for messages and is never parsed or run.
    - Update the file's top comment: callers pass the tool and its arguments as a list, and nothing is quoted or split.
    - Add the tests listed under "Unit Tests, written in step 2" to `packages-zig/node-utils-zig/src/test/in-process-tools.test.zig`.
    - Run `mise exec -- zig build test -Dtest-file=node-utils-zig/in-process-tools.test.zig`. It must exit 0.

3. **Move every tool call to an argument list.** Import `runTool` and `runToolLogged` from `node_utils.in_process_tools` in each file and stop importing `exec`/`execLogged` where they become unused. Every path goes in as its own list element, unquoted. Build the lists with `std.ArrayList([]const u8)` where parts are optional.
    - `packages-zig/tools-zig/src/lib/image.zig`
        - `verifyImageMagick`: `runTool(..., tools, "magick", &.{"-version"})`.
        - `getImageInfo`: `runToolLogged(..., "magick", &.{ "identify", "-format", "%w %h", self.filePath }, null)`.
        - `getExifData`: `runToolLogged(..., "magick", &.{ "identify", "-format", "%[EXIF:*]", self.filePath }, null)`.
        - `resize`: list `self.filePath`, `"-resize"`, geometry, `"-strip"`, then `"-quality"` and the quality text when given, then the output: `"<format>:<outputPath1>"` as one element (made with `std.mem.concat`) when `options.format` is set, otherwise `outputPath1`. Replace the `command` ArrayList(u8) with this list and pass it to `runToolLogged` with the existing `IResizeValidation`.
        - `getDominantColorInner`: `&.{ self.filePath, "-resize", "1x1!", "-format", "%[fx:int(mean.r*255)],%[fx:int(mean.g*255)],%[fx:int(mean.b*255)]", "info:" }`.
        - `transform`: replace the `transformCommand` ArrayList(u8) with an `ArrayList([]const u8)` of the operations (`"-flop"`; `"-rotate"`, number text). When it is not empty, run `magick` with `self.filePath`, the operations, then `outputPath`.
    - `packages-zig/tools-zig/src/lib/video.zig`
        - `verifyFfprobe` / `verifyFfmpeg`: `runTool(..., "ffprobe", &.{"-version"})` and `runTool(..., "ffmpeg", &.{"-version"})`.
        - `getVideoInfoInner`: `runTool(..., "ffprobe", &.{ "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", self.filePath })`.
        - `extractScreenshot`: list `"-i"`, `self.filePath`, `"-ss"`, the time written with `utils.js_number.writeNumber` into its own `std.Io.Writer.Allocating`, `"-vframes"`, `"1"`, `"-q:v"`, the quality number text written the same way, `"-y"`, `outputPath`. Keep the argument order as it is today, so `video.probe.test.zig:179` keeps passing unchanged.
    - `packages-zig/tools-zig/src/lib/heic.zig`
        - `getHeicInfo`: `runTool(..., "ffprobe", &.{ "-v", "error", "-print_format", "json", "-show_streams", "-show_stream_groups", filePath })`.
        - `decodeHeic`: `runToolLogged(..., "ffmpeg", &.{ "-v", "error", "-i", filePath, "-frames:v", "1", "-q:v", "2", outputPath }, null)`.
    - `apps/cli-zig/src/test/worker-pool.test.zig`, `magickVersionHandler`: replace the `node_utils.exec.exec(..., tools.runner(), "magick -version")` call with `node_utils.in_process_tools.runTool(allocator, io, log, tools.runner(), "magick", &.{"-version"})`.
    - Update the comments in `packages-zig/tools-zig/src/test/image.command.test.zig` (above `resizeArguments`) and `video.probe.test.zig` (above the `extractScreenshot` assertion) that say the command quotes both paths and the runner gets the words with the quotes taken off: they now say the paths are passed as arguments of their own. The asserted strings do not change.
    - Run `mise exec -- zig build test -Dtest-file=tools-zig/image.test.zig -Dtest-file=tools-zig/image.command.test.zig -Dtest-file=tools-zig/video.info.test.zig -Dtest-file=tools-zig/video.probe.test.zig -Dtest-file=tools-zig/heic.test.zig -Dtest-file=tools-zig/tool-verification.test.zig -Dtest-file=node-utils-zig/in-process-tools.test.zig -Dcli-test-file=worker-pool.test.zig`. It must exit 0, including the three tests that failed in step 1.
    - Run `mise exec -- bun run test:cli:zig -- 139`. It must exit 0.

4. **Remove the string route to the runner.** Nothing calls it after step 3.
    - `packages-zig/node-utils-zig/src/lib/in-process-tools.zig`: remove `splitCommand`, `tryRun`, the `in_process_tools` name list and the `handles` field of `InProcessRunner`. Update the doc comments of `InProcessRunner` and `run` so they no longer mention exec or a command being started as a program.
    - `packages-zig/node-utils-zig/src/lib/exec.zig`: remove the `in_process_tools` import, `exec`, `execLogged` and `execLoggedInner`. Replace them with `pub const exec = ziggy_exec.exec;` and `pub const execLogged = ziggy_exec.execLogged;`, beside the existing `ExecResult` and `IValidate` re-exports. Ziggy's functions are `exec(allocator, io, command)` and `execLogged(allocator, io, log, tool, command, validate)` (`ziggy/core/src/lib/exec.zig:31,594` in the pinned `zig-pkg/ziggy-0.0.0-Yh04rtu6...`), with the same body and messages as node-utils' copies minus the runner, and their `ILog` is the one `utils-zig` re-exports (`utils-zig/src/index.zig:16`, `pub const log = @import("ziggy").log`). Rewrite the file's top comment to say it re-exports Ziggy's shell exec and that the built-in tools are run with `in_process_tools.runTool`.
    - Update every caller to the new signatures:
        - `packages-zig/node-api-zig/src/test/marking-tool-programs.zig:48`: `node_utils.exec.exec(allocator, io, <command>)` (drop `log, null`).
        - `packages-zig/node-utils-zig/src/test/exec.test.zig`: every `exec(arena.allocator(), std.testing.io, log, null, <command>)` and `exec(allocator, io, log, null, <command>)` becomes `exec(<allocator>, <io>, <command>)`, dropping `log` and the first `null`. Every `execLogged(arena.allocator(), std.testing.io, log, null, <tool>, <command>, <validate>)` becomes `execLogged(arena.allocator(), std.testing.io, log, <tool>, <command>, <validate>)`: only the `null` after `log` (the runner) goes, and the last argument (`null` or the `.{ .context = &unused, .function = failValidation }` validation) stays. Remove `log` declarations that become unused.
    - Remove `handles` from every `InProcessRunner` built:
        - `packages-zig/media-tools-zig/src/lib/media-tools.zig`: the `.handles = handles` entry and the `ThreadTools.handles` function. Update the comments of `MediaTools.runner` and `ThreadTools.runner` that say "which exec calls".
        - `packages-zig/tools-zig/src/test/fake-tool-runner.zig`: the `.handles` entry and the `handles` function. Update its doc comment ("It handles every tool exec hands a runner, so no command is ever started as a program") to say it answers for the tools runTool calls it for.
        - `apps/cli-zig/src/test/ensure-tools.test.zig`: the `.handles = handlesEveryTool` entry and the `handlesEveryTool` function.
        - `packages-zig/node-utils-zig/src/test/in-process-tools.test.zig`: `RecordingRunner.handles`, its `refused_tool` field and the `.handles` entry.
    - Remove the tests whose subject no longer exists:
        - `packages-zig/node-utils-zig/src/test/in-process-tools.test.zig`: the five `splitCommand` tests, the four `exec ...` tests that hand a command string to a runner, and `tryRun leaves a command for a tool the runner does not handle to the caller`. Remove the `exec` import if unused.
        - `packages-zig/media-tools-zig/src/test/media-tools.test.zig`: `the runner handles magick, ffmpeg and ffprobe and no other tool`.
    - Run `grep -rn --include='*.zig' -e splitCommand -e tryRun -e '\.handles' packages-zig apps | grep -v -e .zig-cache -e zig-pkg -e node_modules`. It must print nothing.
    - Run `mise exec -- bun run test:zig`. It must exit 0.

5. **Update the documentation.**
    - `docs/investigations/media-tools-review.md`:
        - Remove the whole `## Bug` section (the "File paths containing `$`, a backtick or `"` fail" item and its sub-bullets).
        - "How it works", the last bullet (line 17): callers in `packages-zig/tools-zig` pass the tool and an argument list to `runTool` / `runToolLogged` in `node-utils-zig/src/lib/in-process-tools.zig`, which call the runner directly. Remove the mention of `exec`, `splitCommand` and shell-style command strings from it.
        - "`ThreadTools`", line 59: `InProcessRunner` now has only `context` and `run`; change "whose `handles` and `run` ignore `context`" to "whose `run` ignores `context`".
        - "Removing `ThreadTools` and `InProcessRunner`" / "Why they exist": replace "The string commands, `splitCommand` and the shell fallback in `exec` are left over from when the tools were separate programs." with a statement that `node-utils-zig`'s `exec` is now Ziggy's shell exec, re-exported, and the tools are reached through `runTool`.
        - "Proposal": in the delete list, replace "`in-process-tools.zig` (`splitCommand`, `tryRun`)" with "`in-process-tools.zig` (`runTool`, `runToolLogged`)", and remove the bullet "This also fixes the path quoting bug above, since no string is parsed."
        - "Costs": the tests that use `FakeToolRunner` assert the argument list joined with spaces, not command strings; reword "assert command strings" to say that.
        - Leave the "Fix" section as it is: its items are wider than this bug.
    - `docs/mobile-native-media.md`, the `MediaTools` bullet: add one sentence saying Photosphere's code calls the runner with the tool and its arguments as a list (`runTool` / `runToolLogged` in `packages-zig/node-utils-zig/src/lib/in-process-tools.zig`), so no command string is built or parsed, and a path holding a space, `$`, a backtick or `"` reaches the tool unchanged. Say nothing about other characters.
    - Check both docs against `rules/writing.md`, the project's no-em-dash rule and the no-comma-before-"and" rule.

## Unit Tests

All Zig, each with a description comment at the top of the test saying its goal and method. The odd name used below is `Trip $5 \`a\` "b"` plus the file's extension, with the `"b"` part left out on Windows (checked with `builtin.os.tag`), because Windows file names cannot hold `"`. Files are copied with `std.Io.Dir.cwd().copyFile(<source>, std.Io.Dir.cwd(), <destination>, io, .{})`, as `node-api-zig/src/test/import.test.zig:70` does.

### Written in step 1 (real tools through `MediaTools.runner()`)

- `packages-zig/tools-zig/src/test/image.test.zig`
    - `every operation works on a file whose name holds $, a backtick and a double quote`: makes a directory with `makeTempDir` and inside it a subdirectory named `out $x \`y\``, copies `../test/test.jpg` into the directory under the odd name, and runs on the copy:
        - `getInfo` and `getExifData`, each equal to the same call on `../test/test.jpg`.
        - `resize` into the odd subdirectory with `.{ .width = 100, .height = 0, .quality = 90, .format = "jpeg", .ext = "jpg" }`. The `.format = "jpeg"` and `.ext = "jpg"` are what `node-api-zig/src/lib/image.zig:410` passes in production; the width, height and quality are fixed test values (production computes them). The format being set means the `"jpeg:<outputPath1>"` element is used with an odd output path. `describeImage` of the output must equal `describeImage` of a resize of `../test/test.jpg` with the same options.
        - `resize` into the odd subdirectory with `.format = null`, checked the same way, so the plain output path is used too.
        - `transform` into the odd subdirectory with `.rotate = 90`, `describeImage` equal to the same transform of `../test/test.jpg`.
        - `getDominantColor`, equal to the same call on `../test/test.jpg`.
- `packages-zig/tools-zig/src/test/video.info.test.zig`
    - `getInfo and extractScreenshot work on a video whose name holds $, a backtick and a double quote`: copies `../test/multiple-files/test.mp4` under the odd name into a directory from the file's own `makeTempDir`, checks `getInfo` with `expectTestMp4Info`, and `extractScreenshot` to an output path with the odd name and `.jpg`, which must then exist and be read by `tools.getFileInfo` as `image/jpeg` at the video's width and height.
    - `expectTestMp4Info` (`video.info.test.zig:47`) asserts `info.filePath` equals `"../test/multiple-files/test.mp4"`, which the copy's path is not. Give it a first parameter `expectedFilePath: []const u8` and assert `info.filePath` against that. Its two existing callers (`video.info.test.zig:118` and `:196`) pass `"../test/multiple-files/test.mp4"`, so what they assert does not change. The new test passes the copy's path.
- `packages-zig/tools-zig/src/test/heic.test.zig`
    - `getHeicInfo and decodeHeic work on a HEIC whose name holds $, a backtick and a double quote`: copies `../test/heic/tiled.heic` under the odd name into a `std.testing.tmpDir` (path from the file's `tempFilePath`), checks 1000 x 700 from `getHeicInfo`, and that `decodeHeic` to an output with the odd name and `.jpg` gives a JPEG `tools.getFileInfo` reads as 1000 x 700.

### Written in step 2 (`packages-zig/node-utils-zig/src/test/in-process-tools.test.zig`, with its `RecordingRunner`)

- `runTool passes the tool and the arguments to the runner unchanged and returns its output`: arguments include `"a $b \`c\` \"d\".jpg"` and `"%w %h"`; asserts the recorded tool, the argument count, each argument byte for byte, and `stdout`.
- `runTool fails with the tool, its arguments and the output when the tool ends with a non-zero code`: runner exits 1 with output `"no decode delegate"`, arguments `&.{ "x.heic", "-resize", "10x10", "y.jpg" }`; asserts `error.Thrown` and `lastErrorMessage()` equals `"Command failed: magick x.heic -resize 10x10 y.jpg\nno decode delegate"`.
- `runToolLogged logs the command at verbose and returns the output when the tool works and the validation passes`: uses `utils.memory_log.MemoryLog.init(std.testing.allocator, .{ .verbose = true, .debug = false, .tools = false })` and `defer memory.deinit()`; asserts the returned `stdout` and that `memory.stdout()` holds `Executing magick with command: "magick identify -format %w %h a.jpg"`.
- `runToolLogged reports a failed validation as a failure to execute the command`: a validation that returns the reason `"no output file"`; asserts `error.Thrown`, `lastErrorMessage()` equals `Failed to execute command: <description>`, `memory.stderr()` holds `Validation failed for command: <description>\nReason: no output file`, and `memory.stdout()` holds `===\nCommand: <description>\nCommand stdout:\n`.
- `runToolLogged reports a tool that fails as a failure to execute the command`: runner exits 1; asserts `error.Thrown`, `lastErrorMessage()` equals `Failed to execute command: <description>`, and `memory.stderr()` holds that text.

### Existing tests that must keep passing

`image.command.test.zig`, `video.probe.test.zig`, `tool-verification.test.zig`, `image.test.zig`, `video.info.test.zig`, `heic.test.zig`, `media-tools.test.zig`, `exec.test.zig` (call sites only), `apps/cli-zig/src/test/ensure-tools.test.zig`, `apps/cli-zig/src/test/worker-pool.test.zig`.

## Smoke Tests

- `apps/cli-zig/smoke-tests-zig/139-odd-file-names/test.sh` (written in step 1), following the shape of `105-built-in-media-tools/test.sh` (`DESCRIPTION`, `SCRIPT_DIR`, `source "$SCRIPT_DIR/../lib/common.sh"`, `trap cleanup_and_show_summary EXIT`, a `test_odd_file_names` function called with `139`):
    - `test_dir="$(get_test_dir "$test_number")"`, a photos directory `$test_dir/photos` and a database `$test_dir/db`.
    - Copies `$TEST_FILES_DIR/test.jpg`, `$TEST_FILES_DIR/test.png` and `$MULTIPLE_IMAGES_DIR/test.mp4` into the photos directory under names holding a space, `$` and a backtick, written in single quotes so the shell does not expand them (for example `'Trip $5 `a`.jpg'`). When `detect_platform` does not print `win`, the names also hold a `"`. Each copy is checked with `check_exists`.
    - Runs `init`, then `add` of the photos directory through `invoke_command`, passing only the directory (whose name has no special characters), so no odd name goes through `invoke_command`'s `eval`: `"$(get_zig_cli_command) add --db \"$db_dir\" \"$photos_dir\" --verbose --yes"`, expected exit code 0, captured into `add_output`.
    - `expect_output_value "$add_output" "Files added:" "3" ...` and `expect_output_value "$add_output" "Files failed:" "0" ...`.
    - Reads the asset ids from the verbose lines `Added file "<path>" to the database with ID "<id>".` with `grep -o 'to the database with ID "[^"]*"'` and `sed -n 's/.*with ID "\([^"]*\)".*/\1/p'`, with no end-of-line anchor, as test 105 reads the same line. The match starts at the fixed text `to the database with ID "`, which none of the odd names holds, so a `"` in the path cannot be taken for the id. The runner exports `NO_COLOR=1` (`apps/cli-zig/smoke-tests-zig.sh:21`), so the line carries no colour codes, and nothing after the id's closing quote is matched, so a trailing `.` or `\r` does not matter. There must be exactly 3 ids, else `log_error` and `exit 1`. For each id: `check_exists "$db_dir/thumb/$id"` and `expect_image "$db_dir/thumb/$id" "image/jpeg" ...`, as test 105 does. This checks the thumbnails directly, whatever `Files failed` counts.
    - `summary` with `expect_output_value ... "Files imported:" "3"`, then `verify_database "$db_dir"`, then `test_passed`.
- `apps/cli-zig/smoke-tests-zig/139-odd-file-names/test.md` beside it: what the test checks (a JPEG, a PNG and an MP4 named with a space, `$`, a backtick and, except on Windows, a `"` are imported, each with a JPEG thumbnail), how it is run (`bun run test:cli:zig -- 139`) and that it takes no arguments.
- The existing CLI smoke tests that add photos and videos (`04-add-jpg`, `05-add-mp4`, `07-add-multiple`, `105-built-in-media-tools`) cover the unchanged behaviour for ordinary names and run as part of `test:cli:zig`.

## Verify

- `mise exec -- bun run test:zig` exits 0 (all Zig package and CLI unit tests, which also proves every package compiles).
- `mise exec -- bun run test:cli:zig` exits 0, including test 139.
- `mise exec -- bun run test:everything` exits 0 (no `--force`, no script names).
- `grep -rn --include='*.zig' -e splitCommand -e tryRun packages-zig apps | grep -v -e .zig-cache -e zig-pkg -e node_modules` prints nothing.
- `grep -n "## Bug" docs/investigations/media-tools-review.md` prints nothing.
- CI-only: the Windows and macOS runs of the unit tests and of smoke test 139, which this Linux machine cannot run. Nothing above depends on them.

## Notes

- The human chose no documentation-first step and no review stop. Documentation is the last step.
- The human asked that the plan remove the bug from `docs/investigations/media-tools-review.md` and update that doc as required (step 5).
- The fix is the one the investigation names: pass an argument list instead of building a string and parsing it again. `InProcessRunner.run` already takes `tool` and `arguments`, so no runner implementation changes how it runs a tool.
- Commands are run without `tee` or a log file because the global `CLAUDE.md` says a command the agent runs itself returns its output already and is run as it is. That rule is the more specific one for the agent's own runs, so it takes precedence over the testing rule's "capture test output to a file". With no files written, nothing needs a Clean up step.
- The tests are written and run against the unchanged code first (step 1), so each is seen to fail on the bug before the fix makes it pass. This is not a mutated run: no production code is broken to make them fail.
- `node-utils-zig`'s `exec` and `execLogged` become re-exports of Ziggy's. They were Ziggy's code plus the runner hook, and `utils-zig`'s `ILog` is Ziggy's, so the signatures match with no adapter. `exec.test.zig` keeps testing them through `node_utils.exec`. `exec` is still needed for shell commands (`marking-tool-programs.zig` runs `chmod` with it).
- `handles` is removed because `tryRun` was its only reader; leaving it would keep a field nothing calls.
- The docs claim only what the tests cover: a space, `$`, a backtick and `"`. ImageMagick reads `[...]`, `*`, `?` and a `format:` prefix in file names, and ImageMagick and ffmpeg read `%d` in output names and ffmpeg a `protocol:` prefix in input names. How the built tools treat those was not checked while writing this plan, and this plan neither changes it nor says anything about it.
- Not in scope, and left to the investigation's "Fix" section: removing `ThreadTools` and `InProcessRunner`, removing one-time setup of the libraries, and calling the MagickWand/libav C APIs instead of the command-line entry points. `runTool` keeps the `InProcessRunner` parameter so that later change starts from fewer call sites, not more.
- The joined description in `runTool`'s messages is for people reading logs and errors only. It is never parsed or run, so it is not a command string in the sense of the bug.
- The `-ss` placement, the extra `identify`, the swallowed EXIF error and the other items in the investigation are separate findings and are not changed here. Argument order is kept exactly so the existing assertions in `image.command.test.zig` and `video.probe.test.zig` hold without edits to their expected strings.
- The Windows-only loss of the backslash in `\$` came from `splitCommand`, which this plan removes.
- The smoke test passes only the photos directory through `invoke_command`, because `invoke_command` runs its command with `eval` and would reparse an odd name. The CLI finds the odd names itself by listing the directory.
- Production thumbnails are made with `.format = "jpeg"` (`node-api-zig/src/lib/image.zig:410`), so the smoke test expects a JPEG thumbnail for the PNG as well as for the JPEG and the video.
- HEIC is covered by the unit tests only. No existing CLI smoke test imports a HEIC, and this plan does not rely on the CLI's handling of one.
- Nothing is committed, pushed or deleted as a file, so the plan has no Release or Clean up step. The removed tests and functions are edits to files that stay.
