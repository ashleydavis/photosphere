#!/bin/bash
DESCRIPTION="Two databases watching separate folders, both connected to one remote, each end up with the other's photos"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

TEST_NUMBER="${1:-86}"
print_test_header "$TEST_NUMBER" "MULTI DEVICE"

TEST_DIR="$(get_test_dir "$TEST_NUMBER")"
REMOTE_DB="$TEST_DIR/remote-db"
DEVICE_A_DB="$TEST_DIR/device-a-db"
DEVICE_B_DB="$TEST_DIR/device-b-db"
DEVICE_A_PHOTOS="$TEST_DIR/device-a-photos"
DEVICE_B_PHOTOS="$TEST_DIR/device-b-photos"
mkdir -p "$DEVICE_A_PHOTOS" "$DEVICE_B_PHOTOS"

CLI_COMMAND=$(get_cli_command)

# Each device watches its own folder, holding a photo the other one has never seen.
cp "$TEST_FILES_DIR/test.png" "$DEVICE_A_PHOTOS/from-a.png"
cp "$TEST_FILES_DIR/test.jpg" "$DEVICE_B_PHOTOS/from-b.jpg"

# --- Device A imports its photos and creates the remote. ---

invoke_command "Initialize device A" "$CLI_COMMAND init --db $DEVICE_A_DB --yes"
invoke_command "Device A imports its folder" "$CLI_COMMAND watch --db $DEVICE_A_DB $DEVICE_A_PHOTOS --once --yes"
invoke_command "Device A connects to the remote" "$CLI_COMMAND connect --db $DEVICE_A_DB $REMOTE_DB --yes"

REMOTE_ASSETS=$(ls -1 "$REMOTE_DB/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$REMOTE_ASSETS" 1 "The remote holds device A's photo"

# --- Device B imports its own photos and consolidates into the same remote. ---

invoke_command "Initialize device B" "$CLI_COMMAND init --db $DEVICE_B_DB --yes"
invoke_command "Device B imports its folder" "$CLI_COMMAND watch --db $DEVICE_B_DB $DEVICE_B_PHOTOS --once --yes"

CONNECT_OUTPUT=""
invoke_command "Device B connects to the same remote" "$CLI_COMMAND connect --db $DEVICE_B_DB $REMOTE_DB --yes" 0 CONNECT_OUTPUT
expect_output_value "$CONNECT_OUTPUT" "Assets pushed to the remote:" 1 "Device B pushed its own photo"

REMOTE_ASSETS=$(ls -1 "$REMOTE_DB/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$REMOTE_ASSETS" 2 "The remote holds both devices' photos"

invoke_command "Verify the remote" "$CLI_COMMAND verify --db $REMOTE_DB --yes"

# --- Device B already sees both, because connecting made it a replica of the remote. ---

DEVICE_B_LIST=""
invoke_command "List device B" "$CLI_COMMAND list --db $DEVICE_B_DB --yes" 0 DEVICE_B_LIST
expect_output_string "$DEVICE_B_LIST" "from-b.jpg" "Device B still has its own photo"
expect_output_string "$DEVICE_B_LIST" "from-a.png" "Device B has device A's photo"

# --- Device A picks up device B's photo on its next sync. ---

invoke_command "Device A syncs" "$CLI_COMMAND sync --db $DEVICE_A_DB --yes"

DEVICE_A_LIST=""
invoke_command "List device A" "$CLI_COMMAND list --db $DEVICE_A_DB --yes" 0 DEVICE_A_LIST
expect_output_string "$DEVICE_A_LIST" "from-a.png" "Device A still has its own photo"
expect_output_string "$DEVICE_A_LIST" "from-b.jpg" "Device A has device B's photo"

# --- A photo taken on device A afterwards reaches the remote and then device B. ---

cp "$TEST_FILES_DIR/test.webp" "$DEVICE_A_PHOTOS/later-from-a.webp"

invoke_command "Device A imports and syncs the new photo" "$CLI_COMMAND watch --db $DEVICE_A_DB $DEVICE_A_PHOTOS --once --yes"

REMOTE_ASSETS=$(ls -1 "$REMOTE_DB/asset" 2>/dev/null | wc -l | tr -d ' ')
expect_value "$REMOTE_ASSETS" 3 "The remote holds the photo taken after connecting"

invoke_command "Device B syncs" "$CLI_COMMAND sync --db $DEVICE_B_DB --yes"

DEVICE_B_LIST=""
invoke_command "List device B again" "$CLI_COMMAND list --db $DEVICE_B_DB --yes" 0 DEVICE_B_LIST
expect_output_string "$DEVICE_B_LIST" "later-from-a.webp" "Device B has the photo device A took later"

test_passed
