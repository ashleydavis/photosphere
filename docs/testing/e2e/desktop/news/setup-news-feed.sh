#!/usr/bin/env bash
#
# Sets up a local news feed for the news-notifications manual test and prints
# the PHOTOSPHERE_NEWS_URL export line to point the desktop app at it.
#
set -euo pipefail

NEWS_FILE="/tmp/photosphere-news.yaml"

cat > "$NEWS_FILE" <<'EOF'
items:
  - id: smoke-test-001
    message: "Welcome to Photosphere"
    color: success
    link:
      label: "Read more"
      url: "https://example.com/read"
    action:
      label: "Try it"
      url: "https://example.com/try"
  - id: smoke-test-002
    message: "Second item"
EOF

echo "Wrote news feed to $NEWS_FILE"
echo "Run this to point the app at it:"
echo "  export PHOTOSPHERE_NEWS_URL=\"file://$NEWS_FILE\""
