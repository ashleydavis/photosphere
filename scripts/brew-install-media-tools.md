# Installing the media tools on a macOS runner

`brew-install-media-tools.sh` installs ImageMagick at a pinned version with Homebrew, together with any other formulae named on its command line at their current versions. The macOS and iOS release workflows run it wherever they need the system ImageMagick and ffmpeg (the smoke suites check the files the CLI writes with `magick identify` and `ffprobe`).

## Why ImageMagick is pinned

A plain `brew install imagemagick` installs whatever version the runner image's cached Homebrew data names, so the version changes whenever GitHub rolls out a new runner image, with no change to this repository. ImageMagick 7.1.2-35 arrived that way and broke CLI smoke test 04 (add-jpg) on macOS arm64.

ImageMagick's own XML parser skips the attributes of every tag nested in an `rdf:Seq` or `rdf:Bag`, and while skipping it stops at the first `/` it meets, even inside a quoted attribute value. The XMP packet of `test/test.jpg`, an Ultra HDR photo, has `<Container:Item ... Item:Mime="image/jpeg"/>` inside an `rdf:Seq`, which is valid XML, and the parser takes the `/` of `image/jpeg` for the end of the tag and fails with `missing >`. 7.1.2-34 parses it the same way, but threw the error away; 7.1.2-35 reports it, so `magick identify -format "%m" test.jpg` prints `identify: ParseError missing > @ warning/xml-tree.c/NewXMLTree/1808.` before `JPEG`.

Upstream's fix for its issue 9078 (the same message, on Photoshop XMP) exempts only `rdf:` and `x:xmpmeta` tags, so it does not cover `Container:Item`. Move the pin only to a release that reads `test/test.jpg` with nothing on stderr.

## How it pins

The script adds a local tap, `photosphere/pinned`, and puts homebrew-core's own `imagemagick.rb` into it, fetched from the homebrew-core commit that published the pinned version's bottles. Homebrew then pours the bottle it built for that version, from its registry, by the checksum in that file. Nothing in the formula is changed.

| Runner | Version | homebrew-core commit |
| --- | --- | --- |
| arm64 | 7.1.2-34 | `135be67cb371d0ccf7a748e2a0ccae9a7b24a415` |
| x86_64 | 7.1.2-30 | `9b41cfbc4eccb693595d3b74a28f221659ba4803` |

Intel is on an older version because Homebrew stopped building Intel macOS bottles after 7.1.2-30; a later version would be built from source on every run.

The script fails if `magick -version` does not report the pinned version afterwards, and on any architecture it has no pin for.

## Using it

```
bash scripts/brew-install-media-tools.sh ffmpeg tree
```

## Arguments

- `formula...` are further Homebrew formulae to install alongside ImageMagick, at their current versions. There may be none.
