#!/bin/bash
DESCRIPTION="psi bug builds the GitHub issue URL from the system, the tools and the latest log, and hands it to the platform's opener"

# No browser is started: every run finds a stand-in for the platform's opener that records what it was
# given. On Linux and macOS that is a script in opener-stub/, first on the PATH. On Windows the opener is
# PowerShell under SYSTEMROOT, so the test builds opener-stub/powershell.zig as that PowerShell under a
# SYSTEMROOT of its own, linked to the rest of the real one, and decodes the URL from the arguments it
# records.
#
# That includes the runs with --no-browser, because the TypeScript CLI registers the option as
# `--no-browser`, which commander stores as `browser`, while the command reads `noBrowser`: the option
# changes nothing, and the Zig port reproduces that.
#
# Each CLI's report and opened URL are compared with the TypeScript CLI's for the same state. The one
# field they differ in by design is the runtime version (Node's for TypeScript, Zig's for the port),
# which is replaced before comparing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# The directory of the opener stand-ins.
OPENER_STUB_DIR="$SCRIPT_DIR/opener-stub"

# The variable assignments that make psi bug find the opener stand-in, set by test_bug for the platform.
OPENER_ENVIRONMENT=""

#
# Replaces the runtime version in an issue URL, the one part that differs between the two CLIs.
#
without_runtime_version() {
    local url="$1"
    echo "$url" | sed 's/Node\.js+Version%3A+[^%]*%0A/Node.js+Version%3A+(runtime)%0A/'
}

#
# Waits for the opener stand-in to record a URL, then prints it. Fails the test when none arrives:
# outside Windows the opener runs detached, so it can finish a moment after psi has exited.
#
wait_for_opened_url() {
    local capture_file="$1"
    local attempt
    for attempt in $(seq 1 100); do
        if [ -f "$capture_file" ]; then
            cat "$capture_file"
            return 0
        fi
        sleep 0.1
    done
    log_error "The opener was never asked to open a URL ($capture_file was not written)"
    exit 1
}

#
# Builds a SYSTEMROOT at the given directory that holds everything the real one holds except Windows
# PowerShell: each entry of the real SYSTEMROOT but System32 is linked in, and so is each entry of its
# System32 but WindowsPowerShell. The TypeScript CLI is a Bun executable, and Windows does not start it
# under a SYSTEMROOT without the rest of Windows in it (Git Bash reports exit code 127 with no output),
# so a SYSTEMROOT holding nothing but PowerShell only works for the Zig CLI. Prints the SYSTEMROOT as a
# Windows path.
#
build_system_root() {
    local system_root="$1"
    local real_system_root
    real_system_root="$(cygpath -u "$SYSTEMROOT")"

    local windows_entries=()
    local system32_entries=()
    local entry
    for entry in "$real_system_root"/*; do
        local entry_name
        entry_name="${entry##*/}"
        if [ "${entry_name,,}" = "system32" ]; then
            local system32_entry
            for system32_entry in "$entry"/*; do
                local system32_entry_name
                system32_entry_name="${system32_entry##*/}"
                if [ "${system32_entry_name,,}" != "windowspowershell" ]; then
                    system32_entries+=("$system32_entry")
                fi
            done
        else
            windows_entries+=("$entry")
        fi
    done

    # Native Windows symbolic links, which Windows follows, not the copies Git Bash makes by default.
    mkdir -p "$system_root/System32"
    if ! MSYS=winsymlinks:nativestrict ln -s "${windows_entries[@]}" "$system_root/" >&2; then
        log_error "Could not link the entries of $real_system_root into $system_root" >&2
        exit 1
    fi
    if ! MSYS=winsymlinks:nativestrict ln -s "${system32_entries[@]}" "$system_root/System32/" >&2; then
        log_error "Could not link the entries of $real_system_root/System32 into $system_root/System32" >&2
        exit 1
    fi
    cygpath -w "$system_root"
}

#
# Builds the PowerShell stand-in (opener-stub/powershell.zig) as powershell.exe under a SYSTEMROOT in
# the test directory (see build_system_root), where psi bug and the `open` package look for PowerShell,
# and prints that SYSTEMROOT as a Windows path.
#
build_powershell_stand_in() {
    local test_dir="$1"
    local system_root="$test_dir/windows"
    build_system_root "$system_root" > /dev/null
    local powershell_dir="$system_root/System32/WindowsPowerShell/v1.0"
    mkdir -p "$powershell_dir"
    zig build-exe "$OPENER_STUB_DIR/powershell.zig" --cache-dir "$test_dir/zig-cache" -femit-bin="$powershell_dir/powershell.exe" >&2
    cygpath -w "$system_root"
}

#
# Waits for the opener stand-in to record what it was given and leaves the URL in the named variable.
# The PowerShell stand-in records its arguments, which must be those the `open` package gives
# PowerShell, the last a base64 UTF-16LE `Start "<url>"`, so the URL is decoded from that.
#
read_opened_url() {
    local capture_file="$1"
    local url_var_name="$2"

    # TODO: on Windows the TypeScript `psi bug` starts PowerShell without `detached` (the `open` package's
    # default there) and exits straight away, so Bun's libuv kills PowerShell with psi, usually before it
    # runs `Start`. The Zig CLI mirrors that on purpose (startAttachedToThisProcess in open.zig) until both
    # are fixed. Whether the stand-in recorded its arguments before it was killed is a race, and psi has
    # exited by now, so nothing more will arrive: the URL is read only when it was recorded, and is left
    # empty otherwise. Wait for it on every platform again once both CLIs are fixed.
    if [ "$(detect_platform)" = "win" ] && [ ! -f "$capture_file" ]; then
        log_info "The opener was killed with psi before it recorded a URL ($capture_file was not written)"
        eval "$url_var_name=\"\""
        return
    fi

    local captured
    captured="$(wait_for_opened_url "$capture_file")" || exit 1
    if [ "$(detect_platform)" != "win" ]; then
        eval "$url_var_name=\"\$captured\""
        return
    fi

    expect_value "$(echo "$captured" | grep -c '')" "6" "PowerShell is started with six arguments"
    expect_value "$(echo "$captured" | head -n 5 | paste -sd ' ')" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand" "PowerShell is started with the options of the open package"
    local start_command
    start_command="$(echo "$captured" | sed -n 6p | base64 -d | iconv -f UTF-16LE -t UTF-8)"
    expect_output_string "$start_command" '^Start "https://github\.com/.*"$' "PowerShell is told to start the URL"
    local decoded_url
    decoded_url="$(echo "$start_command" | sed 's/^Start "\(.*\)"$/\1/')"
    eval "$url_var_name=\"\$decoded_url\""
}

#
# Expects the Zig CLI's report to be the TypeScript CLI's.
#
# TODO: on Windows the TypeScript CLI can lose the end of its report. `psi bug` writes it with
# process.stdout.write (the clack outro) and exits at once, and Bun's writes to a pipe on Windows finish
# later on its event loop (a libuv write), which process.exit does not wait for: the Release workflow saw
# only the heading, written long before. That is the Bun runtime, not the TypeScript code, which writes the
# whole report, so the Zig CLI writes it all. On Windows the TypeScript report is expected to be the start
# of the Zig one and to hold at least the heading. Compare them whole again once the TypeScript CLI flushes
# its output before exiting.
#
expect_same_report() {
    local zig_report="$1"
    local ts_report="$2"
    local description="$3"

    if [ "$(detect_platform)" != "win" ]; then
        expect_value "$zig_report" "$ts_report" "$description"
        return
    fi

    expect_output_string "$ts_report" "Photosphere Bug Report" "$description: the TypeScript CLI printed the heading"
    if [ "${zig_report:0:${#ts_report}}" != "$ts_report" ]; then
        log_error "$description: expected the TypeScript report to be the start of the Zig report, got
$ts_report
and
$zig_report"
        exit 1
    fi
    log_success "$description (the TypeScript report is the start of the Zig one)"
}

#
# Runs `bug` with the given arguments through the Zig CLI and the TypeScript CLI, each with the opener
# stand-in's environment (OPENER_ENVIRONMENT) and PHOTOSPHERE_TMP_DIR at the given directory. Expects the two to report
# the same and to open the same URL, and leaves the Zig CLI's report and URL in the named variables.
#
run_bug_with_both() {
    local description="$1"
    local bug_arguments="$2"
    local bug_tmp_dir="$3"
    local capture_prefix="$4"
    local report_var_name="$5"
    local url_var_name="$6"

    local zig_report
    invoke_command "$description with the Zig CLI" "$OPENER_ENVIRONMENT BUG_OPENER_CAPTURE_FILE=\"$capture_prefix-zig.txt\" PHOTOSPHERE_TMP_DIR=\"$bug_tmp_dir\" $(get_zig_cli_command) bug $bug_arguments" 0 "zig_report"
    local zig_url
    read_opened_url "$capture_prefix-zig.txt" "zig_url"

    local ts_report
    invoke_command "$description with the TypeScript CLI" "$OPENER_ENVIRONMENT BUG_OPENER_CAPTURE_FILE=\"$capture_prefix-ts.txt\" PHOTOSPHERE_TMP_DIR=\"$bug_tmp_dir\" $(get_cli_command) bug $bug_arguments" 0 "ts_report"
    local ts_url
    read_opened_url "$capture_prefix-ts.txt" "ts_url"

    expect_same_report "$zig_report" "$ts_report" "$description: the Zig CLI reports what the TypeScript CLI reports"
    if [ -n "$zig_url" ] && [ -n "$ts_url" ]; then
        expect_value "$(without_runtime_version "$zig_url")" "$(without_runtime_version "$ts_url")" "$description: the Zig CLI opens the URL the TypeScript CLI opens"
    fi

    eval "$report_var_name=\"\$zig_report\""
    eval "$url_var_name=\"\$zig_url\""
}

test_bug() {
    local test_number="$1"
    print_test_header "$test_number" "BUG"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local db_dir="$test_dir/bug-db"

    # The environment that makes each psi bug find the opener stand-in: on Windows a SYSTEMROOT holding
    # the PowerShell stand-in (PowerShell is found through SYSTEMROOT, not the PATH), elsewhere the PATH.
    if [ "$(detect_platform)" = "win" ]; then
        local system_root
        system_root="$(build_powershell_stand_in "$test_dir")" || exit 1
        OPENER_ENVIRONMENT="SYSTEMROOT=\"$system_root\""
    else
        OPENER_ENVIRONMENT="PATH=\"$OPENER_STUB_DIR:$PATH\""
    fi

    # The bug report reads the log directory under PHOTOSPHERE_TMP_DIR. A directory of its own keeps
    # the logs of the rest of this test out of it until the test puts one there.
    local bug_tmp_dir="$test_dir/bug-tmp"
    mkdir -p "$bug_tmp_dir"

    # --- 1. No log file yet. ---

    local report
    local url
    run_bug_with_both "Report a bug" "--yes" "$bug_tmp_dir" "$test_dir/no-log" "report" "url"

    expect_output_string "$report" "Photosphere Bug Report" "The report has its heading"
    expect_output_string "$report" "Bug report opened in browser!" "The report says it was opened"
    expect_output_string "$report" "^Title: Bug Report$" "The report has the default title"
    expect_output_string "$report" "^Photosphere Version: " "The report names the version"
    expect_output_string "$report" "^System: " "The report names the system"
    expect_output_string "$report" "^Log File: None available$" "The report says there is no log file"
    expect_output_string "$report" "https://github.com" "The URL is not printed when it was opened" false

    # On Windows the URL is there only when the opener recorded it before it was killed (see read_opened_url).
    if [ -n "$url" ]; then
        expect_output_string "$url" "^https://github\.com/ashleydavis/photosphere/issues/new?title=Bug+Report&body=%23%23+Bug+Description" "The URL opens a new issue with the report as its body"
        expect_output_string "$url" "&labels=bug$" "The URL labels the issue as a bug"
        expect_output_string "$url" "%23%23+Tool+Versions%0A-+ImageMagick%3A+ImageMagick+v" "The body lists the ImageMagick version"
        expect_output_string "$url" "%0A-+FFmpeg%3A+ffmpeg+v" "The body lists the ffmpeg version"
        expect_output_string "$url" "%60%60%60%0ANo+log+file+available%0A%60%60%60" "The body says there is no log file"
    fi

    # --- 2. --no-browser changes nothing, in either CLI. ---

    local no_browser_report
    local no_browser_url
    run_bug_with_both "Report a bug with --no-browser" "--yes --no-browser" "$bug_tmp_dir" "$test_dir/no-browser" "no_browser_report" "no_browser_url"
    expect_value "$no_browser_report" "$report" "--no-browser reports what a run without it reports"
    if [ -n "$no_browser_url" ] && [ -n "$url" ]; then
        expect_value "$no_browser_url" "$url" "--no-browser opens the URL a run without it opens"
    fi

    # --- 3. The latest log file is named in the report and its header is in the issue body. ---

    invoke_command "Create a database" "$(get_zig_cli_command) init --db \"$db_dir\" --yes"
    ts_verify "$db_dir"
    invoke_command "Summarize it, writing its log files" "PHOTOSPHERE_TMP_DIR=\"$bug_tmp_dir\" $(get_zig_cli_command) summary --db \"$db_dir\" --yes"

    # A command writes a log and an error log, psi-<time>.log and psi-<time>-errors.log.
    local logs_dir="$bug_tmp_dir/tmp/photosphere/logs"
    local log_files
    log_files="$(ls "$logs_dir" | grep '^psi-.*\.log$')"
    local log_file_count
    log_file_count="$(echo "$log_files" | grep -c .)"
    expect_value "$log_file_count" "2" "The summary wrote its log and its error log"

    local log_report
    local log_url
    run_bug_with_both "Report a bug with a log file" "--yes" "$bug_tmp_dir" "$test_dir/with-log" "log_report" "log_url"
    expect_output_string "$log_report" "^Log File: .*photosphere.logs.psi-[^ ]*\.log$" "The report names one of the log files"
    expect_output_string "$log_report" "Log File Information:" "The report says how to attach the log file"
    if [ -n "$log_url" ]; then
        expect_output_string "$log_url" "%23%23+Log+Header%0A%60%60%60%0A.*---+Log+Start+---%0A%60%60%60" "The body holds the log file's header, up to its start marker"
        expect_output_string "$log_url" "No+log+file+available" "The body no longer says there is no log file" false
    fi

    # --- 4. No opener and no tools on the PATH. ---

    # The `open` package does not wait to hear whether its opener started, so the TypeScript CLI says
    # the report was opened even when there is nothing to open it with, and so must the port.
    local empty_path_dir="$test_dir/empty-path"
    mkdir -p "$empty_path_dir"

    # On Windows the opener is not looked for on the PATH but under SYSTEMROOT, so SYSTEMROOT is one
    # with no PowerShell in it.
    local no_opener_environment=""
    if [ "$(detect_platform)" = "win" ]; then
        local no_opener_system_root
        no_opener_system_root="$(build_system_root "$test_dir/windows-without-powershell")" || exit 1
        no_opener_environment="SYSTEMROOT=\"$no_opener_system_root\""
    fi

    # Run from the sources, the TypeScript CLI is started through `bun run`, which finds bun and a
    # shell on the PATH. With an empty PATH it is started by bun's full path instead.
    local ts_cli_command
    ts_cli_command="$(get_cli_command)"
    if [ "$USE_BINARY" != "true" ]; then
        ts_cli_command="\"$(command -v bun)\" index.ts"
    fi

    local no_opener_report
    invoke_command "Report a bug with nothing on the PATH with the Zig CLI" "$no_opener_environment PATH=\"$empty_path_dir\" PHOTOSPHERE_TMP_DIR=\"$bug_tmp_dir\" $(get_zig_cli_command) bug --yes" 0 "no_opener_report"
    expect_output_string "$no_opener_report" "Bug report opened in browser!" "The report says it was opened although no opener could start"

    local ts_no_opener_report
    invoke_command "Report a bug with nothing on the PATH with the TypeScript CLI" "$no_opener_environment PATH=\"$empty_path_dir\" PHOTOSPHERE_TMP_DIR=\"$bug_tmp_dir\" $ts_cli_command bug --yes" 0 "ts_no_opener_report"
    expect_same_report "$no_opener_report" "$ts_no_opener_report" "The Zig CLI reports a missing opener as the TypeScript CLI does"

    test_passed
}

test_bug "${1:-96}"
