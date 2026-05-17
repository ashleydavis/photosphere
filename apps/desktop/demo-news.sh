#!/usr/bin/env bash
#
# Manual demo for the desktop app's news/update notifications.
# Reuses the 5-item feed from test/demo-news.yaml.
#
# Run from anywhere:
#   bash apps/desktop/demo-news.sh
#
# How it works:
#   - Points PHOTOSPHERE_NEWS_URL at the in-repo test/demo-news.yaml.
#   - Uses an isolated, auto-cleaned scratch config dir, so your real
#     ~/.config/photosphere/desktop.toml is not touched.
#   - Launches `bun run dev` from apps/desktop/, which bundles main/preload
#     and starts Electron.
#   - The desktop shows the oldest UNSEEN item per startup. Since the
#     scratch dir is fresh each run, you always see demo-001-welcome.
#
# Notes:
#   - The update notification ("📦 A new version is available" pill in the
#     navbar) requires a real release tag on GitHub that differs from the
#     running build. In dev mode the version is 'dev' and the check
#     short-circuits, so the pill will not appear.

set -u

# ─── locate the script and sibling demo feed ──────────────────────────────────
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

# ─── launch ───────────────────────────────────────────────────────────────────
export PHOTOSPHERE_NEWS_URL="file://$DEMO_FEED"
export PHOTOSPHERE_CONFIG_DIR="$DEMO_CONFIG"
cd "$SCRIPT_DIR"
bun run dev
