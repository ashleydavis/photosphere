#!/usr/bin/env bash
# Installs the media tools the smoke suites need on a macOS CI runner with Homebrew: ImageMagick at a pinned
# version, and whatever other formulae are named on the command line at Homebrew's current version.
#
# ImageMagick is pinned because the version a plain `brew install imagemagick` gives is whatever the runner
# image's cached Homebrew data says, so it changes under the workflows whenever GitHub rolls out a new image.
# ImageMagick 7.1.2-35 broke the CLI smoke tests that way: its XML parser stops at the first "/" inside a
# quoted attribute value of any tag nested in an rdf:Seq or rdf:Bag, so it rejects the valid XMP packet of
# test/test.jpg (an Ultra HDR photo, whose Container:Item tags carry Item:Mime="image/jpeg"), and 7.1.2-35
# reports that to stderr as "ParseError missing >" on every read of the file, where 7.1.2-34 kept it to
# itself. Upstream's fix for its issue 9078 exempts only rdf: and x:xmpmeta tags, which does not cover
# Container:Item, so a later release is not known to be clear of it. Move the pin only to a release that reads
# test/test.jpg with nothing on stderr.
#
# The formula is homebrew-core's own file at the commit that published the pinned version's bottles, so the
# bottle poured is the one Homebrew built, fetched from Homebrew's registry by its checksum. The pinned
# commit differs by architecture because Homebrew stopped building Intel macOS bottles after 7.1.2-30.
#
# Usage: scripts/brew-install-media-tools.sh [formula...]
#   formula   Further Homebrew formulae to install alongside ImageMagick, at their current versions.
set -euo pipefail

case "$(uname -m)" in
    arm64)
        # imagemagick: update 7.1.2-34 bottle.
        formulaCommit="135be67cb371d0ccf7a748e2a0ccae9a7b24a415"
        imagemagickVersion="7.1.2-34"
        ;;
    x86_64)
        # imagemagick: update 7.1.2-30 bottle. The last version with an Intel macOS bottle.
        formulaCommit="9b41cfbc4eccb693595d3b74a28f221659ba4803"
        imagemagickVersion="7.1.2-30"
        ;;
    *)
        echo "brew-install-media-tools.sh: no pinned ImageMagick for architecture $(uname -m)" >&2
        exit 1
        ;;
esac

tap="photosphere/pinned"
if ! brew tap | grep -qx "$tap"; then
    brew tap-new --no-git "$tap"
fi
formulaDir="$(brew --repository "$tap")/Formula"
mkdir -p "$formulaDir"
curl --fail --silent --show-error --location --retry 3 \
    --output "$formulaDir/imagemagick.rb" \
    "https://raw.githubusercontent.com/Homebrew/homebrew-core/$formulaCommit/Formula/i/imagemagick.rb"

brew install "$tap/imagemagick" "$@"

versionOutput="$(magick -version)"
installedVersion="${versionOutput%%$'\n'*}"
echo "$installedVersion"
case "$installedVersion" in
    "Version: ImageMagick $imagemagickVersion "*)
        ;;
    *)
        echo "brew-install-media-tools.sh: expected ImageMagick $imagemagickVersion, got: $installedVersion" >&2
        exit 1
        ;;
esac
