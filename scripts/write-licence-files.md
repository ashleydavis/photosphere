# write-licence-files.sh

Writes the licence files that every distributed build of Photosphere carries into one directory. The packaging scripts (`apps/photosphere/scripts/package-*.sh`) put them in every package they make, and the release workflows (`.github/workflows/release-*.yml`) put them in every CLI archive they publish, so each build that leaves the repository has them. What the files are for, and how they meet the LGPL that FFmpeg is used under, is in [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

```
bash scripts/write-licence-files.sh <directory>
```

- `<directory>`: where the files go. It is created when it does not exist, and files of the same names in it are replaced.

The files it writes:

- `LICENSE.txt`: Photosphere's own licence, the repository's `LICENSE`.
- `THIRD-PARTY-NOTICES.md`: the repository's list of the bundled libraries and their licences.
- `COPYING.LGPLv2.1.txt`: the GNU Lesser General Public License 2.1, FFmpeg's own copy (`third-party/ffmpeg/vendor/ffmpeg/COPYING.LGPLv2.1`).
- `THIRD-PARTY-LICENCES.txt`: the licence texts the vendored libraries carry (FFmpeg's `LICENSE.md`, ImageMagick's `LICENSE` and `NOTICE`, libjpeg's `README`, libpng's `LICENSE` and libwebp's `COPYING` and `PATENTS`), one after another under the path each came from.
- `SOURCE.txt`: the commit the build was made from, the addresses of its complete source in the public repository, the FFmpeg version, where its configure options and the change made to it are, and how to rebuild the program with a modified FFmpeg.

The commit is read with `git rev-parse HEAD` in the checkout the script is in, so run it from the checkout the build was made from. It fails, and so fails the package, when any of the files it copies is missing.
