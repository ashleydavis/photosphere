#!/usr/bin/env bash

# Builds the compiled mk and bdb executables, and the Zig psi, a CLI smoke suite runs, into a directory that
# belongs to that one run, and names them for the tests. See test-cli-binaries.md.
#
# Source this from a suite runner, which builds, and from a test library, which reads the paths:
#   source "<repo>/apps/cli-zig/test-cli-binaries.sh"
#
# It defines functions only.
#
# The suites used to build into the package's own bin/x64/<platform>/ through `bun run build-win` and
# friends, one path for every run on the machine. On Windows a running executable cannot be replaced,
# so a suite rebuilding psi.exe while another suite, or another worktree's run, was executing it
# failed with "failed to move executable ... EPERM". The package scripts stay as they are for people
# building by hand; the suites no longer touch their output.

# The directory of this file, the Zig CLI, which the mk-cli and bdb-cli packages sit beside.
_TEST_CLI_BINARIES_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The per-test temporary directory allocator the binaries' directory comes from.
source "$_TEST_CLI_BINARIES_CLI_DIR/../../scripts/lib/test-lib.sh"

#
# Prints the file name an executable has on this host: the name itself, or the name with .exe on
# Windows.
# Usage: test_cli_executable_name <psi|mk|bdb>
#
test_cli_executable_name() {
    local name="$1"
    case "$(uname -s)" in
        CYGWIN*|MINGW*|MSYS*)
            printf '%s.exe\n' "$name"
            ;;
        *)
            printf '%s\n' "$name"
            ;;
    esac
}

#
# Prints the `bun build --target` for this host, the same target the package's build-linux, build-win,
# build-mac-x64 and build-mac-arm64 scripts use.
#
test_cli_bun_target() {
    case "$(uname -s)" in
        Linux*)
            echo "bun-linux-x64-baseline"
            ;;
        Darwin*)
            if [ "$(uname -m)" = "arm64" ]; then
                echo "bun-darwin-arm64"
            else
                echo "bun-darwin-x64"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "bun-windows-x64"
            ;;
        *)
            echo "No bun build target is known for this host: $(uname -s)" >&2
            return 1
            ;;
    esac
}

#
# Builds mk and bdb into a newly allocated directory of this run's own and exports it as
# PHOTOSPHERE_CLI_BIN_DIR, which test_cli_binary_path reads in this shell and in every test it starts.
#
# Builds once per shell: a second call, such as `setup,all`, returns at once. The directory is recorded
# in TEST_CLI_BINARIES_OWNED_DIR, which is deliberately not exported, so remove_test_cli_binaries
# removes only what this shell built and never a directory a parent handed down.
#
# The flags are those of the package.json build scripts, with only the output file changed.
#
build_test_cli_binaries() {
    if [ -n "${TEST_CLI_BINARIES_OWNED_DIR:-}" ]; then
        return 0
    fi

    local target
    target="$(test_cli_bun_target)" || return 1

    local bin_dir
    bin_dir="$(photosphere_test_temp_dir cli-binaries)" || return 1

    # Recorded before building, so a build that fails part way is still cleaned up.
    TEST_CLI_BINARIES_OWNED_DIR="$bin_dir"
    export PHOTOSPHERE_CLI_BIN_DIR="$bin_dir"

    # Each executable in a directory of its own, because bun writes index.js.map beside each one and
    # the two would overwrite each other's. Each build also runs from that directory, with the entry
    # points named by absolute path, because bun writes the executable to a temporary .bun-build file in
    # its working directory before moving it to --outfile: run from the package, an interrupted or
    # failed build left that file, over 100MB, in the source tree.
    echo "Building mk and bdb for $target into $bin_dir"
    local cli_dir="$_TEST_CLI_BINARIES_CLI_DIR"
    mkdir -p "$bin_dir/mk" "$bin_dir/bdb"
    if ! (cd "$bin_dir/mk" && bun build --compile --minify --sourcemap --target="$target" --outfile "$bin_dir/mk/$(test_cli_executable_name mk)" "$cli_dir/../mk-cli/src/index.ts"); then
        echo "Failed to build mk into $bin_dir/mk" >&2
        return 1
    fi
    if ! (cd "$bin_dir/bdb" && bun build --compile --minify --sourcemap --target="$target" --outfile "$bin_dir/bdb/$(test_cli_executable_name bdb)" "$cli_dir/../bdb-cli/src/index.ts"); then
        echo "Failed to build bdb into $bin_dir/bdb" >&2
        return 1
    fi
}

#
# Builds the Zig port of psi (apps/cli-zig) with `zig build` and installs it under a newly allocated
# directory of this run's own, exported as PHOTOSPHERE_ZIG_CLI_DIR, which test_zig_cli_path reads.
#
# The *-zig suites used to run whatever a plain `zig build` had last left in the repository's
# zig-out/bin, one path for every run on the machine and never rebuilt by the suites themselves, so a
# run could test a stale build, and a rebuild while another run was executing psi.exe fails on
# Windows the way the TypeScript build did. The build cache is shared, which zig makes safe for
# concurrent builds; only the installed executable is the run's own.
#
# Builds once per shell, like build_test_cli_binaries, recording what it built in
# TEST_ZIG_CLI_OWNED_DIR (not exported) for remove_test_cli_binaries.
#
build_test_zig_cli() {
    if [ -n "${TEST_ZIG_CLI_OWNED_DIR:-}" ]; then
        return 0
    fi

    local install_dir
    install_dir="$(photosphere_test_temp_dir zig-cli)" || return 1

    # Recorded before building, so a build that fails part way is still cleaned up.
    TEST_ZIG_CLI_OWNED_DIR="$install_dir"
    export PHOTOSPHERE_ZIG_CLI_DIR="$install_dir"

    echo "Building the Zig CLI into $install_dir"
    if ! (cd "$_TEST_CLI_BINARIES_CLI_DIR/../.." && zig build --prefix "$install_dir"); then
        echo "Failed to build the Zig CLI into $install_dir" >&2
        return 1
    fi
}

#
# Prints the path of the Zig psi build_test_zig_cli installed, failing loudly when this run built none.
#
test_zig_cli_path() {
    if [ -z "${PHOTOSPHERE_ZIG_CLI_DIR:-}" ]; then
        echo "The Zig CLI was asked for, but PHOTOSPHERE_ZIG_CLI_DIR is not set: nothing built it for this run." >&2
        return 1
    fi
    printf '%s/bin/%s\n' "$PHOTOSPHERE_ZIG_CLI_DIR" "$(test_cli_executable_name psi)"
}

#
# Prints the path of one of the executables build_test_cli_binaries built, failing loudly when this
# run built none rather than letting a test run whatever an empty path resolves to.
# Usage: test_cli_binary_path <mk|bdb>
#
test_cli_binary_path() {
    local name="$1"
    if [ -z "${PHOTOSPHERE_CLI_BIN_DIR:-}" ]; then
        echo "The compiled $name was asked for, but PHOTOSPHERE_CLI_BIN_DIR is not set: nothing built the executables for this run. Run the suite with --binary, which builds them." >&2
        return 1
    fi
    printf '%s/%s/%s\n' "$PHOTOSPHERE_CLI_BIN_DIR" "$name" "$(test_cli_executable_name "$name")"
}

#
# Removes what build_test_cli_binaries built in this shell, by name, and then the emptied directories.
#
# Called from a suite's exit trap, after the suite has stopped the processes it started, because on
# Windows an executable still running cannot be deleted. About 300MB a run, which is why these are
# removed when the per-test directories beside them are left for inspection: an executable is not
# evidence of anything a failure would need. A file or directory that will not go is reported, not
# ignored.
#
remove_test_cli_binaries() {
    remove_test_zig_cli

    local bin_dir="${TEST_CLI_BINARIES_OWNED_DIR:-}"
    if [ -z "$bin_dir" ]; then
        return 0
    fi

    local file
    for file in \
        "mk/$(test_cli_executable_name mk)" "mk/index.js.map" \
        "bdb/$(test_cli_executable_name bdb)" "bdb/index.js.map"; do
        if [ -e "$bin_dir/$file" ] && ! rm -f "$bin_dir/$file"; then
            echo "WARNING: could not remove $bin_dir/$file" >&2
        fi
    done

    # The temporary file bun leaves in its working directory when a build is interrupted or fails, one
    # file at a time. The pattern stays as it is when nothing matches, and the -e test skips it then.
    local sub_dir
    local temporary_file
    for sub_dir in mk bdb; do
        for temporary_file in "$bin_dir/$sub_dir"/.*.bun-build; do
            if [ -e "$temporary_file" ] && ! rm -f "$temporary_file"; then
                echo "WARNING: could not remove $temporary_file" >&2
            fi
        done
    done

    for sub_dir in mk bdb; do
        if [ -d "$bin_dir/$sub_dir" ] && ! rmdir "$bin_dir/$sub_dir"; then
            echo "WARNING: could not remove $bin_dir/$sub_dir" >&2
        fi
    done
    if ! rmdir "$bin_dir"; then
        echo "WARNING: could not remove $bin_dir" >&2
    fi

    TEST_CLI_BINARIES_OWNED_DIR=""
}

#
# Removes, by name, the Zig psi build_test_zig_cli installed in this shell (and its .pdb on Windows),
# then the emptied directories. Called by remove_test_cli_binaries, so a suite's exit trap needs only
# the one call. Anything that will not go is reported, not ignored.
#
remove_test_zig_cli() {
    local install_dir="${TEST_ZIG_CLI_OWNED_DIR:-}"
    if [ -z "$install_dir" ]; then
        return 0
    fi

    local file
    for file in "bin/$(test_cli_executable_name psi)" "bin/psi.pdb"; do
        if [ -e "$install_dir/$file" ] && ! rm -f "$install_dir/$file"; then
            echo "WARNING: could not remove $install_dir/$file" >&2
        fi
    done
    if [ -d "$install_dir/bin" ] && ! rmdir "$install_dir/bin"; then
        echo "WARNING: could not remove $install_dir/bin" >&2
    fi
    if ! rmdir "$install_dir"; then
        echo "WARNING: could not remove $install_dir" >&2
    fi

    TEST_ZIG_CLI_OWNED_DIR=""
}
