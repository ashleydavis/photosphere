#!/usr/bin/env bash
# Starts a local MinIO server with a fresh bucket for a manual test, creates the test's database in it and sets the CLI up to use
# it, at an address a phone on the same network can reach. See start-minio.md.
#
# Usage:
#   bun run start-minio -- <name> [--from <fixture>] [--add <path>] [--encrypt] [--key <pem file>] [--empty] [--lan-ip <address>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSI="$REPO_ROOT/zig-out/bin/psi"

usage() {
    echo "Usage: bun run start-minio -- <name> [--from <fixture>] [--add <path>] [--encrypt] [--key <pem file>] [--empty] [--lan-ip <address>]" >&2
    exit 2
}

#
# Prints this machine's address on the local network, the one a phone on the same Wi-Fi reaches it by.
#
find_lan_ip() {
    local address=""
    case "$(uname -s)" in
        Linux)
            address="$(hostname -I | awk '{ print $1 }')"
            ;;
        Darwin)
            address="$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)"
            ;;
    esac
    if [ -z "$address" ]; then
        echo "ERROR: could not work out this machine's address on the local network. Pass it with --lan-ip <address>." >&2
        exit 1
    fi
    printf '%s\n' "$address"
}

if [ $# -lt 1 ]; then
    usage
fi
name="$1"
shift
stateDir="$REPO_ROOT/tmp/minio/$name"
envFile="$REPO_ROOT/tmp/minio/$name.env"
fromFixture=""
addPath=""
encrypt="false"
keyFile=""
empty="false"
lanIp=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from)
            fromFixture="$2"
            shift 2
            ;;
        --add)
            addPath="$2"
            shift 2
            ;;
        --encrypt)
            encrypt="true"
            shift
            ;;
        --key)
            keyFile="$2"
            shift 2
            ;;
        --empty)
            empty="true"
            shift
            ;;
        --lan-ip)
            lanIp="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done
if [ -n "$fromFixture" ] && [ ! -d "$REPO_ROOT/test/dbs/$fromFixture" ]; then
    echo "ERROR: there is no fixture database at test/dbs/$fromFixture." >&2
    exit 1
fi
if [ -z "$lanIp" ]; then
    lanIp="$(find_lan_ip)"
fi

(cd "$REPO_ROOT" && zig build)

# The state directory is reused by name, and s3-emulator.sh empties its data when it starts, so every start is a fresh bucket. The
# CLI's config and vault are files of their own here, so nothing touches the keychain or the database list the CLI normally uses.
mkdir -p "$stateDir/config" "$stateDir/vault"
rm -f "$stateDir/config/databases.toml" "$stateDir/vault/vault.json"
bash "$REPO_ROOT/scripts/s3-emulator.sh" start "$stateDir/s3"
source "$stateDir/s3/env"

database="s3:$S3_EMULATOR_BUCKET/$name"
cat > "$envFile" <<ENV
export PATH="$REPO_ROOT/zig-out/bin:\$PATH"
export PHOTOSPHERE_CONFIG_DIR="$stateDir/config"
export PHOTOSPHERE_VAULT_DIR="$stateDir/vault"
export PHOTOSPHERE_VAULT_TYPE=plaintext
export AWS_ACCESS_KEY_ID="$S3_EMULATOR_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_EMULATOR_SECRET_KEY"
export AWS_ENDPOINT="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_ENDPOINT_URL="http://127.0.0.1:$S3_EMULATOR_PORT"
export AWS_REGION=us-east-1
export S3_DB="$database"
ENV
source "$envFile"

# The key the database is encrypted with, which the CLI takes as the name of a secret in its vault. --encrypt generates one named
# after the entry and attaches it to the entry. --key imports a PEM file the test made itself, which `psi secrets import` names after
# the file, and leaves it off the entry, because the test puts that key on the phone by hand.
keyArgs=()
if [ "$encrypt" = "true" ]; then
    keyArgs=(--key "$name-key")
elif [ -n "$keyFile" ]; then
    # The secret's name is read back from what the import says it chose, which depends on the file's extension.
    importOutput="$("$PSI" secrets import --yes --private-key "$keyFile")"
    echo "$importOutput"
    keyName="$(printf '%s\n' "$importOutput" | sed -n 's/.*Key imported as "\(.*\)".*/\1/p')"
    if [ -z "$keyName" ]; then
        echo "ERROR: could not tell which name psi secrets import gave the key." >&2
        exit 1
    fi
    keyArgs=(--key "$keyName")
fi

if [ -n "$fromFixture" ]; then
    if [ "${#keyArgs[@]}" -gt 0 ]; then
        echo "ERROR: --from copies a fixture as it is, unencrypted, so it cannot be combined with --encrypt or --key." >&2
        exit 2
    fi
    "$PSI" replicate --db "$REPO_ROOT/test/dbs/$fromFixture" --dest "$database" --yes
elif [ "$empty" != "true" ]; then
    if [ "$encrypt" = "true" ]; then
        "$PSI" init --db "$database" "${keyArgs[@]}" --generate-key --yes
    else
        "$PSI" init --db "$database" "${keyArgs[@]}" --yes
    fi
    if [ -n "$addPath" ]; then
        "$PSI" add "$REPO_ROOT/$addPath" --db "$database" "${keyArgs[@]}" --yes
    fi
fi

credentials="$(jq -n \
    --arg endpoint "http://$lanIp:$S3_EMULATOR_PORT" \
    --arg accessKeyId "$S3_EMULATOR_ACCESS_KEY" \
    --arg secretAccessKey "$S3_EMULATOR_SECRET_KEY" \
    '{ endpoint: $endpoint, region: "us-east-1", accessKeyId: $accessKeyId, secretAccessKey: $secretAccessKey }')"
"$PSI" secrets add --yes --name "$name-s3" --type s3-credentials --value "$credentials"
entryArgs=(--s3-cred "$name-s3")
if [ "$encrypt" = "true" ]; then
    entryArgs+=(--encryption-key "$name-key")
fi
"$PSI" dbs add --yes --name "$name" --path "$database" "${entryArgs[@]}"

echo
echo "S3 database ready: $database"
echo "  Endpoint for the phone: http://$lanIp:$S3_EMULATOR_PORT  (region us-east-1)"
echo "  Access key: $S3_EMULATOR_ACCESS_KEY  Secret key: $S3_EMULATOR_SECRET_KEY"
echo "  On this machine the CLI knows it as the entry '$name', with the credentials secret '$name-s3'."
echo "Set up this terminal for the CLI with:"
echo "  source tmp/minio/$name.env"
