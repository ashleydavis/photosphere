#!/usr/bin/env bash
# Generates the three headers ImageMagick's own configure script writes for a target, using Zig as the C compiler, and places
# them in config/<zig-target>/. See generate-config.md.
set -euo pipefail

if [ $# -lt 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: generate-config.sh <zig-target> [<libc-file>]" >&2
    echo "  <zig-target>  x86_64-linux-gnu, aarch64-linux-gnu, x86_64-linux-android, aarch64-linux-android," >&2
    echo "                x86_64-windows-gnu, aarch64-windows-gnu, x86_64-windows-msvc, x86_64-macos, aarch64-macos," >&2
    echo "                aarch64-ios, aarch64-ios-simulator or x86_64-ios-simulator" >&2
    echo "  <libc-file>   Zig's libc file for the NDK, required for the Android targets" >&2
    exit 1
fi

ZIG_TARGET="$1"
LIBC_FILE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGEMAGICK_DIR="$SCRIPT_DIR/vendor/imagemagick"
LIBJPEG_DIR="$SCRIPT_DIR/vendor/libjpeg"
WORK_DIR="$REPO_ROOT/tmp/imagemagick-config/$ZIG_TARGET"
OUTPUT_DIR="$SCRIPT_DIR/config/$ZIG_TARGET"

if [ ! -f "$IMAGEMAGICK_DIR/configure" ] || [ ! -f "$LIBJPEG_DIR/jpeglib.h" ]; then
    echo "ERROR: third-party/imagemagick/vendor/imagemagick and third-party/imagemagick/vendor/libjpeg are not there. Run third-party/imagemagick/update-imagemagick.sh and third-party/imagemagick/update-libjpeg.sh." >&2
    exit 1
fi

ZIG="$(command -v zig)"
# The target the compiler is given. On Linux with glibc it names the glibc version, so the answers are for the headers of that version
# whatever glibc the machine running this script has: 2.35 is old enough that a program built from them runs where glibc is newer,
# and new enough that the headers glibc later removed (such as sys/sysctl.h, gone in 2.32) are not counted on.
COMPILER_TARGET="$ZIG_TARGET"
case "$ZIG_TARGET" in
    x86_64-linux-gnu | aarch64-linux-gnu)
        COMPILER_TARGET="$ZIG_TARGET.2.35"
        ;;
esac
LDFLAGS_FOR_TARGET=""
# Extra arguments for the compiler: the iOS SDK, which Zig does not ship and which Xcode provides.
SDK_ARGUMENT=""
# The machine running configure, which config.guess names, except where it is changed below. config.guess is run with sh, because its
# first line names /usr/bin/sh, which macOS does not have.
CONFIGURE_BUILD="$(sh "$IMAGEMAGICK_DIR/config/config.guess")"
case "$ZIG_TARGET" in
    x86_64-linux-gnu)
        CONFIGURE_HOST="x86_64-pc-linux-gnu"
        ;;
    aarch64-linux-gnu)
        CONFIGURE_HOST="aarch64-unknown-linux-gnu"
        ;;
    x86_64-linux-android | aarch64-linux-android)
        CONFIGURE_HOST="${ZIG_TARGET}"
        if [ -z "$LIBC_FILE" ]; then
            echo "ERROR: $ZIG_TARGET needs the NDK's libc file as the second argument (see apps/photosphere/scripts/android-common.sh)." >&2
            exit 1
        fi
        # Zig has no C library for Android; the libc file names the NDK's. Linking an executable (which configure's
        # checks do) needs the dynamic form, because the NDK's libc is a shared library.
        export ZIG_LIBC="$(cd "$(dirname "$LIBC_FILE")" && pwd)/$(basename "$LIBC_FILE")"
        LDFLAGS_FOR_TARGET="-dynamic"
        ;;
    x86_64-windows-gnu)
        CONFIGURE_HOST="x86_64-w64-mingw32"
        ;;
    x86_64-windows-msvc)
        # configure has no host name for the MSVC ABI, so it is told the MinGW one, which gives it Windows. Its checks are answered
        # by the compiler, which is Zig for the MSVC target and reads the Windows SDK's headers, so this runs only on Windows with
        # Visual Studio or its Build Tools.
        CONFIGURE_HOST="x86_64-w64-mingw32"
        # Git Bash is MSYS2, which config.guess names mingw64, and on a mingw64 build machine configure converts its install paths
        # with winpath.sh, which fails under Git Bash and writes its error into the headers. Named as MSYS2, the paths are left
        # as they are for every other target.
        CONFIGURE_BUILD="x86_64-pc-msys"
        ;;
    aarch64-windows-gnu)
        CONFIGURE_HOST="aarch64-w64-mingw32"
        ;;
    x86_64-macos)
        CONFIGURE_HOST="x86_64-apple-darwin"
        ;;
    aarch64-macos)
        CONFIGURE_HOST="aarch64-apple-darwin"
        ;;
    aarch64-ios | aarch64-ios-simulator | x86_64-ios-simulator)
        # Zig ships no iOS headers, so the SDK of Xcode is used, which only a Mac has.
        if ! command -v xcrun >/dev/null 2>&1; then
            echo "ERROR: $ZIG_TARGET needs the iOS SDK, so run this on a Mac with Xcode." >&2
            exit 1
        fi
        case "$ZIG_TARGET" in
            aarch64-ios)
                SDK_NAME="iphoneos"
                ;;
            *)
                SDK_NAME="iphonesimulator"
                ;;
        esac
        CONFIGURE_HOST="${ZIG_TARGET%%-*}-apple-darwin"
        if [ "$CONFIGURE_HOST" = "aarch64-apple-darwin" ]; then
            CONFIGURE_HOST="arm-apple-darwin"
        fi
        SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
        SDK_ARGUMENT="--sysroot=$SDK_PATH"
        # Zig ships no C library for iOS and finds neither the SDK's headers nor its libSystem from the sysroot alone, so it is given a
        # libc file naming the SDK's usr/include and usr/lib, as third-party/zlib-ng/support/apple-sdk.zig gives the build.
        mkdir -p "$WORK_DIR"
        printf 'include_dir=%s/usr/include\nsys_include_dir=%s/usr/include\ncrt_dir=%s/usr/lib\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n' "$SDK_PATH" "$SDK_PATH" "$SDK_PATH" > "$WORK_DIR/libc.txt"
        export ZIG_LIBC="$WORK_DIR/libc.txt"
        ;;
    *)
        echo "ERROR: unknown target '$ZIG_TARGET'." >&2
        exit 1
        ;;
esac

# configure finds libpng, libwebp and zlib only through pkg-config, and without one it leaves their delegates off and says nothing,
# which builds an ImageMagick that cannot read a PNG. Git Bash has no pkg-config, so it is checked for here.
if ! command -v pkg-config >/dev/null 2>&1; then
    echo "ERROR: pkg-config is not on the PATH. configure finds libpng, libwebp and zlib through it, and would turn their delegates off without it." >&2
    exit 1
fi

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/build" "$WORK_DIR/jpeg-include" "$WORK_DIR/no-pkgconfig"

# Configure takes the compiler as one program, so Zig's is wrapped.
printf '#!/bin/sh\nexec "%s" cc -target %s %s "$@"\n' "$ZIG" "$COMPILER_TARGET" "$SDK_ARGUMENT" > "$WORK_DIR/bin/cc"
printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$WORK_DIR/bin/ar"
printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$WORK_DIR/bin/ranlib"
chmod +x "$WORK_DIR/bin/cc" "$WORK_DIR/bin/ar" "$WORK_DIR/bin/ranlib"

# configure asks pkg-config about zlib, libpng and libwebp, which the Zig build makes and which are not installed anywhere yet,
# so pkg-config is pointed at a directory of its own holding a description of each, with the versions of the vendored source.
# Nothing installed on the machine can be found instead.
write_pkg_config_file() {
    printf 'Name: %s\nDescription: %s\nVersion: %s\nLibs: -lm\nCflags:\n' "$1" "$1" "$2" > "$WORK_DIR/no-pkgconfig/$1.pc"
}
write_pkg_config_file zlib 1.3.1
write_pkg_config_file libpng "$(sed -n 1p "$SCRIPT_DIR/vendor/libpng/VENDORED_VERSION")"
write_pkg_config_file libwebp "$(sed -n 1p "$SCRIPT_DIR/vendor/libwebp/VENDORED_VERSION")"

# The JPEG delegate check wants the library's headers, including a jconfig.h, which libjpeg's own configure makes from
# jconfig.cfg and which the build (build.zig) makes the same way.
cp "$LIBJPEG_DIR/jpeglib.h" "$LIBJPEG_DIR/jerror.h" "$LIBJPEG_DIR/jmorecfg.h" "$WORK_DIR/jpeg-include/"
sed -e 's/^#undef HAVE_PROTOTYPES/#define HAVE_PROTOTYPES/' \
    -e 's/^#undef HAVE_UNSIGNED_CHAR/#define HAVE_UNSIGNED_CHAR/' \
    -e 's/^#undef HAVE_UNSIGNED_SHORT/#define HAVE_UNSIGNED_SHORT/' \
    -e 's/^#undef HAVE_STDDEF_H/#define HAVE_STDDEF_H/' \
    -e 's/^#undef HAVE_STDLIB_H/#define HAVE_STDLIB_H/' \
    "$LIBJPEG_DIR/jconfig.cfg" > "$WORK_DIR/jpeg-include/jconfig.h"

# The delegates are the three the mobile builds had: JPEG, PNG and zlib. Everything else ImageMagick can use is off, so
# nothing on the machine running this script changes the result. The libraries themselves are built by build.zig and are
# not there yet, so the checks that look for them are answered here: PKG_CHECK_MODULES takes the variables as set (it
# would otherwise ask pkg-config), and the one link check for libjpeg is answered through configure's cache variable.
cd "$WORK_DIR/build"
CC="$WORK_DIR/bin/cc" AR="$WORK_DIR/bin/ar" RANLIB="$WORK_DIR/bin/ranlib" \
    CFLAGS="-O2" LDFLAGS="$LDFLAGS_FOR_TARGET" \
    JPEG_CFLAGS="-I$WORK_DIR/jpeg-include" JPEG_LIBS="-lm" \
    PKG_CONFIG_LIBDIR="$WORK_DIR/no-pkgconfig" PKG_CONFIG_PATH="" \
    ac_cv_lib_jpeg_jpeg_read_header=yes \
    "$IMAGEMAGICK_DIR/configure" \
    --host="$CONFIGURE_HOST" --build="$CONFIGURE_BUILD" \
    --disable-shared --enable-static --disable-openmp --disable-opencl \
    --without-magick-plus-plus --without-perl --disable-docs --disable-installed \
    --with-quantum-depth=16 --enable-hdri --without-x --enable-zero-configuration \
    --with-jpeg --with-png --with-zlib --with-webp \
    --without-tiff --without-heic --without-freetype \
    --without-fontconfig --without-xml --without-bzlib --without-lzma \
    --without-fftw --without-dps --without-djvu --without-openexr \
    --without-jbig --without-jp2 --without-lcms --without-openjp2 \
    --without-pango --without-raqm --without-raw --without-wmf \
    --without-jxl --without-lqr --without-flif --without-fpx \
    --without-gslib --without-gvc --without-rsvg --without-zstd \
    --without-libzip --without-autotrace --without-gdi32 --without-uhdr --without-heic --without-openjp2 \
    --without-utilities --no-create > configure.log 2>&1 || {
    echo "ERROR: configure failed. See $WORK_DIR/build/configure.log" >&2
    exit 1
}

# Configure is told to leave the files to config.status, which is run for the three outputs the build needs. The rest
# (man pages, pkg-config files, the Perl and C++ bindings' scripts) are of no use to it, and their templates are not vendored.
./config.status --quiet config/config.h MagickCore/version.h MagickCore/magick-baseconfig.h >> configure.log 2>&1 || {
    echo "ERROR: config.status failed. See $WORK_DIR/build/configure.log" >&2
    exit 1
}

# A delegate configure could not find is left off without an error, so each one the build links is checked for in the result.
for delegate in JPEG PNG WEBP ZLIB; do
    if ! grep -q "^#define MAGICKCORE_${delegate}_DELEGATE 1$" MagickCore/magick-baseconfig.h; then
        echo "ERROR: configure left the $delegate delegate off. See $WORK_DIR/build/configure.log" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR/MagickCore"
cp MagickCore/magick-baseconfig.h MagickCore/version.h "$OUTPUT_DIR/MagickCore/"
echo "Wrote $OUTPUT_DIR/MagickCore/magick-baseconfig.h and version.h"
