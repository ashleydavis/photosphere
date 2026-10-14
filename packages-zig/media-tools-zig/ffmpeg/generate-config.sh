#!/usr/bin/env bash
# Runs FFmpeg's own configure script and make, with Zig as the C compiler, for a target, and keeps what the Zig build needs from
# the result in config/<zig-target>/. See generate-config.md.
set -euo pipefail

if [ $# -lt 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: generate-config.sh <zig-target> [<libc-file>]" >&2
    echo "  <zig-target>  x86_64-linux-gnu, aarch64-linux-gnu, x86_64-linux-android, aarch64-linux-android," >&2
    echo "                x86_64-windows-gnu, aarch64-windows-gnu, x86_64-windows-msvc, x86_64-macos, aarch64-macos," >&2
    echo "                aarch64-ios, aarch64-ios-simulator or x86_64-ios-simulator (a Mac with Xcode only)" >&2
    echo "  <libc-file>   Zig's libc file for the NDK, required for the Android targets" >&2
    exit 1
fi

ZIG_TARGET="$1"
LIBC_FILE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FFMPEG_DIR="$REPO_ROOT/vendor/ffmpeg"
WORK_DIR="$REPO_ROOT/tmp/ffmpeg-config/$ZIG_TARGET"
OUTPUT_DIR="$SCRIPT_DIR/config/$ZIG_TARGET"

if [ ! -f "$FFMPEG_DIR/configure" ]; then
    echo "ERROR: vendor/ffmpeg is not there. Run scripts/update-ffmpeg.sh." >&2
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
EXTRA_LDFLAGS=""
# The suffix of a program's file name, which names the programs make is asked to plan.
EXECUTABLE_SUFFIX=""
# Extra arguments for the compiler: the iOS SDK, which Zig does not ship and which Xcode provides.
SDK_ARGUMENT=""
case "$ZIG_TARGET" in
    x86_64-linux-gnu)
        TARGET_ARGUMENTS=(--arch=x86_64 --target-os=linux)
        ;;
    aarch64-linux-gnu)
        TARGET_ARGUMENTS=(--arch=aarch64 --target-os=linux)
        ;;
    x86_64-linux-android | aarch64-linux-android)
        TARGET_ARGUMENTS=(--arch="${ZIG_TARGET%%-*}" --target-os=android)
        if [ -z "$LIBC_FILE" ]; then
            echo "ERROR: $ZIG_TARGET needs the NDK's libc file as the second argument (see apps/photosphere/scripts/android-common.sh)." >&2
            exit 1
        fi
        # Zig has no C library for Android; the libc file names the NDK's. Linking an executable (which configure's checks do)
        # needs the dynamic form, because the NDK's libc is a shared library.
        export ZIG_LIBC="$(cd "$(dirname "$LIBC_FILE")" && pwd)/$(basename "$LIBC_FILE")"
        EXTRA_LDFLAGS="-dynamic"
        ;;
    x86_64-windows-gnu)
        TARGET_ARGUMENTS=(--arch=x86_64 --target-os=mingw32)
        EXECUTABLE_SUFFIX=".exe"
        ;;
    x86_64-windows-msvc)
        # win64 rather than mingw32, so that configure takes the C library to be Microsoft's, which it also checks the compiler
        # for. The compiler is Zig for the MSVC target, which reads the Windows SDK's headers, so this runs only on Windows with
        # Visual Studio or its Build Tools.
        TARGET_ARGUMENTS=(--arch=x86_64 --target-os=win64)
        EXECUTABLE_SUFFIX=".exe"
        ;;
    aarch64-windows-gnu)
        TARGET_ARGUMENTS=(--arch=aarch64 --target-os=mingw32)
        EXECUTABLE_SUFFIX=".exe"
        ;;
    x86_64-macos)
        TARGET_ARGUMENTS=(--arch=x86_64 --target-os=darwin)
        ;;
    aarch64-macos)
        TARGET_ARGUMENTS=(--arch=aarch64 --target-os=darwin)
        ;;
    aarch64-ios | aarch64-ios-simulator | x86_64-ios-simulator)
        if ! command -v xcrun >/dev/null 2>&1; then
            echo "ERROR: $ZIG_TARGET needs Apple's iOS SDK, which only a Mac with Xcode has (xcrun was not found)." >&2
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
        case "$ZIG_TARGET" in
            x86_64-*)
                TARGET_ARGUMENTS=(--arch=x86_64 --target-os=darwin)
                ;;
            *)
                TARGET_ARGUMENTS=(--arch=aarch64 --target-os=darwin)
                ;;
        esac
        SDK_ARGUMENT="--sysroot=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
        ;;
    *)
        echo "ERROR: unknown target '$ZIG_TARGET'." >&2
        exit 1
        ;;
esac

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/build" "$WORK_DIR/tmp"
# configure makes its test programs in the temporary directory, which is under the work directory and not the machine's.
export TMPDIR="$WORK_DIR/tmp"

# Configure takes the compiler as one program, so Zig's is wrapped. The host compiler makes the programs FFmpeg's make runs while it
# builds, so it is for this machine.
cat > "$WORK_DIR/bin/cc" <<WRAPPER
#!/bin/sh
# configure gives the linker options Zig's linker does not take (Apple's -Wl,-dynamic,-search_paths_first and the Windows executable
# options of mingw), so they are left out of the link tests it makes.
for argument; do
    shift
    case "\$argument" in
        -Wl,-dynamic,-search_paths_first | -Wl,--pic-executable,-e,mainCRTStartup)
            ;;
        *)
            set -- "\$@" "\$argument"
            ;;
    esac
done
exec "$ZIG" cc -target $COMPILER_TARGET $SDK_ARGUMENT "\$@"
WRAPPER
printf '#!/bin/sh\nexec env -u ZIG_LIBC "%s" cc "$@"\n' "$ZIG" > "$WORK_DIR/bin/host-cc"
printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$WORK_DIR/bin/ar"
printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$WORK_DIR/bin/ranlib"
printf '#!/bin/sh\nexec "%s" nm "$@"\n' "$ZIG" > "$WORK_DIR/bin/nm"
chmod +x "$WORK_DIR/bin/cc" "$WORK_DIR/bin/host-cc" "$WORK_DIR/bin/ar" "$WORK_DIR/bin/ranlib" "$WORK_DIR/bin/nm"

# zlib is the same zlib-ng the rest of the program is built over, built for the target by the Zig build.
ZLIB_DIR="$WORK_DIR/zlib"
(cd "$REPO_ROOT" && zig build zlib -Dzlib-only=true ${LIBC_FILE:+--libc "$LIBC_FILE"} -Dtarget="$ZIG_TARGET" -p "$ZLIB_DIR")

# The paths in the arguments are relative to the directory configure runs in, because configure writes its arguments into config.h
# and a path of this machine would end up in a file that is kept in the repository.

# What is built is what the app runs: every decoder, demuxer, parser and bitstream filter (the app reads whatever the user's
# photos and videos are), the file protocol, and for output only what writing one JPEG still takes (the mjpeg encoder, the image2
# and mjpeg muxers and the filters a conversion to one picture uses). No external library but zlib, no hardware acceleration, no
# network and no devices. The result is licensed LGPL version 2.1 or later: configure says so at its end, and none of its
# --enable-gpl or --enable-nonfree options is given.
cd "$WORK_DIR/build"
"$FFMPEG_DIR/configure" \
    --cc=../bin/cc --host-cc=../bin/host-cc --ar=../bin/ar --ranlib=../bin/ranlib --nm=../bin/nm \
    --enable-cross-compile "${TARGET_ARGUMENTS[@]}" \
    --extra-cflags=-I../zlib/include --extra-ldflags="-L../zlib/lib $EXTRA_LDFLAGS" \
    --disable-autodetect --enable-zlib \
    --disable-doc --disable-debug --disable-network --disable-avdevice \
    --disable-x86asm --disable-hwaccels \
    --disable-encoders --enable-encoder=mjpeg \
    --disable-muxers --enable-muxer=image2,mjpeg,null \
    --disable-protocols --enable-protocol=file \
    --disable-filters --enable-filter=buffer,buffersink,scale,format,null,nullsink,transpose,hflip,vflip,rotate,fps,trim,setpts,crop \
    > configure.log 2>&1 || {
    echo "ERROR: configure failed. See $WORK_DIR/build/configure.log" >&2
    exit 1
}

# configure decides HAVE_SYSCTL by linking a call to sysctl, and Zig's stand-in for glibc has every symbol glibc ever had,
# including the ones it keeps only for programs built long ago. glibc 2.32 and later have neither the header nor a function a new
# program can link, so on Linux with glibc the answer is wrong and is corrected here. FFmpeg uses sysctl for BSD and macOS only.
case "$ZIG_TARGET" in
    x86_64-linux-gnu | aarch64-linux-gnu)
        sed -i.bak 's/^#define HAVE_SYSCTL 1$/#define HAVE_SYSCTL 0/' config.h
        ;;
esac

# The files configure and make write that the sources include or that are lists of the components, and the sources of the
# resources of the command line programs, which make writes from files it compresses.
mkdir -p fftools/resources
make V=1 libavutil/ffversion.h fftools/resources/graph.html.c fftools/resources/graph.css.c > make-generated.log 2>&1 || {
    echo "ERROR: make could not write the generated files. See $WORK_DIR/build/make-generated.log" >&2
    exit 1
}

# The commands make would run to build the libraries and the two programs hold which source files are built and with which flags.
make -n -B V=1 libavutil/libavutil.a libavcodec/libavcodec.a libavformat/libavformat.a libswscale/libswscale.a \
    libswresample/libswresample.a libavfilter/libavfilter.a "ffmpeg_g$EXECUTABLE_SUFFIX" "ffprobe_g$EXECUTABLE_SUFFIX" > make-plan.log 2>&1 || {
    echo "ERROR: make could not plan the build. See $WORK_DIR/build/make-plan.log" >&2
    exit 1
}

# The plan names the sources relative to the source directory FFmpeg's make was started for ("src/" or "./src/").
sed -i.bak 's| \./src/| src/|g' make-plan.log

rm -f "$WORK_DIR/lists.txt" "$WORK_DIR/flags.txt" "$WORK_DIR/fftools-flags.txt" "$WORK_DIR/includes.txt"
{
    # A line per source file of a library: the library, then the path under vendor/ffmpeg.
    grep ' -c -o ' make-plan.log | grep -v 'ffbuild/bin2c' | sed -n 's|^.* -c -o [^ ]* src/\([^ ]*\)$|\1|p' | while read -r source; do
        case "$source" in
            fftools/*)
                ;;
            *)
                printf '%s %s\n' "${source%%/*}" "$source"
                ;;
        esac
    done
    # A line per object of each program: the program, then the object's path (the source has the same path with .c).
    for program in ffmpeg ffprobe; do
        grep -- " -o ${program}_g$EXECUTABLE_SUFFIX " make-plan.log | tr ' ' '\n' | grep '^fftools/.*\.o$' | grep -v 'fftools/fftoolsres.o' | while read -r object; do
            printf '%s %s\n' "$program" "${object%.o}"
        done
    done
} > "$WORK_DIR/lists.txt"

# The compiler flags a file is built with: the preprocessor and optimisation flags of one compile command, without the warnings
# FFmpeg asks for (the ones that switch a warning off stay, because they keep clang from stopping at code FFmpeg's own build
# accepts), the dependency files, the include directories (the Zig build adds its own) and the file names. The libraries and the
# command line programs are built with different flags (only the libraries define HAVE_AV_CONFIG_H).
flags_of() {
    grep " -c -o $1 " make-plan.log | head -1 | tr ' ' '\n' | grep -v '^$' | grep -v -e '^-I' -e '^-MMD$' -e '^-MF$' -e '^-MT$' -e '^-c$' -e '^-o$' -e '\.d$' -e '\.o$' -e '\.c$' -e '/cc$' -e '^-Q' | awk '!/^-W/ || /^-Wno-/'
}
flags_of libavutil/adler32.o > "$WORK_DIR/flags.txt"
flags_of fftools/ffmpeg_opt.o > "$WORK_DIR/fftools-flags.txt"
# The include directories under the source directory that configure adds for what the C library lacks (compat/stdbit for stdbit.h,
# compat/dispatch_semaphore on macOS), a directory a line, relative to vendor/ffmpeg.
grep " -c -o libavutil/adler32.o " make-plan.log | head -1 | tr ' ' '\n' | sed -n -e 's|^-I\(\./\)\{0,1\}src/\(.\{1,\}\)$|\2|p' -e 's|^-I.*/vendor/ffmpeg/\(.\{1,\}\)$|\1|p' > "$WORK_DIR/includes.txt"

mkdir -p "$OUTPUT_DIR/libavutil" "$OUTPUT_DIR/libavcodec" "$OUTPUT_DIR/libavformat" "$OUTPUT_DIR/libavfilter" "$OUTPUT_DIR/fftools/resources"
cp config.h config_components.h "$OUTPUT_DIR/"
cp libavutil/avconfig.h libavutil/ffversion.h "$OUTPUT_DIR/libavutil/"
cp libavcodec/codec_list.c libavcodec/parser_list.c libavcodec/bsf_list.c "$OUTPUT_DIR/libavcodec/"
cp libavformat/demuxer_list.c libavformat/muxer_list.c libavformat/protocol_list.c "$OUTPUT_DIR/libavformat/"
cp libavfilter/filter_list.c "$OUTPUT_DIR/libavfilter/"
cp fftools/resources/graph.html.c fftools/resources/graph.css.c "$OUTPUT_DIR/fftools/resources/"
cp "$WORK_DIR/lists.txt" "$WORK_DIR/flags.txt" "$WORK_DIR/fftools-flags.txt" "$WORK_DIR/includes.txt" "$OUTPUT_DIR/"
echo "Wrote $OUTPUT_DIR"
