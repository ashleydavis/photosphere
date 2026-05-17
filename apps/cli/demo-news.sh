#!/usr/bin/env bash
#
# Manual demo for the CLI news/update notifications. Walks through several
# scenarios that exercise the preAction hook and the `psi news` command.
#
# Run from anywhere:
#   bash apps/cli/demo-news.sh
#
# Notes:
#   - The update line ("📦 A new version is available") is NOT shown when
#     running from source (config.version is 'dev'), which short-circuits
#     the GitHub check. To exercise that path, temporarily edit
#     packages/config/src/index.ts and set version to e.g. "0.0.1".

set -u

# ─── locate the script and the shared demo feed ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEMO_FEED="$REPO_ROOT/test/demo-news.yaml"

if [[ ! -f "$DEMO_FEED" ]]; then
    echo "✗ Could not find $DEMO_FEED. Is the repo intact?" >&2
    exit 1
fi

# ─── scratch config dir, auto-cleaned on exit ─────────────────────────────────
DEMO_CONFIG="$(mktemp -d)"
trap 'rm -rf "$DEMO_CONFIG"' EXIT INT TERM

# ─── environment for every run below ──────────────────────────────────────────
export PHOTOSPHERE_NEWS_URL="file://$DEMO_FEED"
export PHOTOSPHERE_CONFIG_DIR="$DEMO_CONFIG"

# ─── helpers ──────────────────────────────────────────────────────────────────
banner() {
    echo
    echo "════════════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════════════════"
}

reset_state() {
    rm -rf "$DEMO_CONFIG"
    mkdir -p "$DEMO_CONFIG"
}

run_psi() {
    # `psi tools` is a quick command with no database requirement, so the
    # preAction hook output is the headline of each invocation.
    ( cd "$SCRIPT_DIR" && bun run start -- "$@" )
}

# ─── scenario 1: nothing seen yet → first preAction hook shows oldest unseen ──
reset_state
banner "1. First command run: preAction hook prints demo-001-welcome"
run_psi tools

banner "2. Second run: preAction hook prints the next unseen item (demo-002-survey)"
run_psi tools

banner "3. Third run: demo-003-blog (action-only, no inline link)"
run_psi tools

# ─── scenario 2: psi news with a mix of seen + unseen ─────────────────────────
banner "4. \`psi news\`: full listing (newest-first); items 001-003 are seen, 004-005 are NEW"
run_psi news

# ─── scenario 3: psi news after everything has been seen ──────────────────────
banner "5. \`psi news\` again: everything is now seen (no (new) markers)"
run_psi news

# ─── scenario 4: replay from a clean slate ────────────────────────────────────
reset_state
banner "6. After resetting state: \`psi news\` shows ALL 5 items as (new)"
run_psi news

# ─── show what got persisted ──────────────────────────────────────────────────
banner "7. Contents of desktop.toml after step 6"
cat "$DEMO_CONFIG/desktop.toml" 2>/dev/null || echo "(no toml written. Did psi news succeed?)"

echo
echo "Done."
