#!/usr/bin/env bash

# Builds the Zig psi a CLI smoke suite runs into a directory that belongs to that one run, and names it
# for the tests. See test-cli-binaries.md.
#
# Source this from a suite runner, which builds, and from a test library, which reads the paths:
#   source "<repo>/apps/cli-zig/test-cli-binaries.sh"
#
# It defines functions only.

# The directory of this file, the Zig CLI.
_TEST_CLI_BINARIES_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The per-test temporary directory allocator the binaries' directory comes from.
source "$_TEST_CLI_BINARIES_CLI_DIR/../../scripts/lib/test-lib.sh"

#
# Prints the file name an executable has on this host: the name itself, or the name with .exe on
# Windows.
# Usage: test_cli_executable_name <name>
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
