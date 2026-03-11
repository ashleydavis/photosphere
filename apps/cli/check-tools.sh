#!/bin/bash
#
# Shared check-tools logic for Photosphere CLI smoke tests.
# Source this file and call run_check_tools, or run the script directly.
# When sourced, uses the caller's get_cli_command, invoke_command, and log_*.
# Sets IMAGEMAGICK_IDENTIFY_CMD in the caller's scope when sourced.
#

_CHECK_TOOLS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_check_tools() {
    echo ""
    echo "=== CHECK TOOLS ==="

    log_info "Changing to CLI directory"
    if ! cd "$_CHECK_TOOLS_SCRIPT_DIR"; then
        log_error "Failed to change to CLI directory"
        return 1
    fi

    local cli_command
    cli_command=$(get_cli_command)
    log_info "Using CLI command: $cli_command"

    # Verify NODE_ENV is set for deterministic UUID generation
    log_info "NODE_ENV is set to: ${NODE_ENV:-'(not set)'}"
    if [ "$NODE_ENV" = "testing" ]; then
        log_success "NODE_ENV=testing is set for deterministic UUID generation"
    else
        log_warning "NODE_ENV is not set to 'testing' - UUIDs may not be deterministic"
    fi

    log_info "Checking for required tools in system PATH"
    invoke_command "Check tools" "$(get_cli_command) tools --yes"
    echo ""

    log_info "Verifying tools are installed and working..."

    # Check that required tools exist and can print versions
    local tools_verified=true

    # Check ImageMagick - determine which version to use
    if command -v magick &> /dev/null; then
        local magick_output
        magick_output=$(magick --version || echo "")
        if [ -n "$magick_output" ]; then
            log_success "ImageMagick 7.x verified (using 'magick identify'):"
            echo "$magick_output"
            IMAGEMAGICK_IDENTIFY_CMD="magick identify"
        else
            log_error "ImageMagick magick command exists but cannot get version"
            tools_verified=false
        fi
    elif command -v identify &> /dev/null; then
        local identify_output
        identify_output=$(identify -version | head -1 || echo "")
        if [ -n "$identify_output" ]; then
            log_success "ImageMagick 6.x verified (using 'identify'):"
            echo "$identify_output"
            IMAGEMAGICK_IDENTIFY_CMD="identify"
        else
            log_error "ImageMagick identify command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ImageMagick not found in system PATH (tried both 'magick' and 'identify')"
        tools_verified=false
    fi

    # Check ffprobe
    if command -v ffprobe &> /dev/null; then
        local ffprobe_version
        ffprobe_version=$(ffprobe -version | head -1 | sed 's/ffprobe version //' | cut -d' ' -f1 || echo "")
        if [ -n "$ffprobe_version" ]; then
            log_success "ffprobe verified: version $ffprobe_version"
        else
            log_error "ffprobe command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ffprobe not found in system PATH"
        tools_verified=false
    fi

    # Check ffmpeg
    if command -v ffmpeg &> /dev/null; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version | head -1 | sed 's/ffmpeg version //' | cut -d' ' -f1 || echo "")
        if [ -n "$ffmpeg_version" ]; then
            log_success "ffmpeg verified: version $ffmpeg_version"
        else
            log_error "ffmpeg command exists but cannot get version"
            tools_verified=false
        fi
    else
        log_error "ffmpeg not found in system PATH"
        tools_verified=false
    fi

    # Fail the tests if any tools are not working
    if [ "$tools_verified" = false ]; then
        log_error "Tool verification failed - some required tools are missing or not working"
        exit 1
    fi

    log_success "All tools verified and working correctly"
}

# When run directly, define minimal helpers and run
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
    log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
    log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    get_cli_command() {
        if [ "${USE_BINARY:-false}" = "true" ]; then
            local platform
            platform="$(uname -s)"
            case "$platform" in
                Linux*)   echo "./bin/x64/linux/psi" ;;
                Darwin*)  echo "./bin/x64/mac/psi" ;;
                CYGWIN*|MINGW*|MSYS*) echo "./bin/x64/win/psi.exe" ;;
                *)       echo "./bin/x64/linux/psi" ;;
            esac
        else
            echo "bun run start --"
        fi
    }
    invoke_command() {
        local description="$1"
        local cmd="$2"
        log_info "$description"
        local output
        output=$(eval "$cmd" 2>&1)
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            log_error "Command failed (exit $exit_code): $cmd"
            echo "$output"
            exit $exit_code
        fi
        echo "$output"
    }
    run_check_tools
    exit $?
fi
