#!/bin/bash
# Cross-compiles ImageMagick 7 + libjpeg + libpng + zlib as STATIC libraries for iOS, for BOTH the
# arm64 device slice and the simulator slice, installing into ios/App/vendor/im/{device,sim}/ which
# the Xcode project's HEADER_SEARCH_PATHS / LIBRARY_SEARCH_PATHS point at (git-ignored). JPEG and PNG
# are the delegates the app exercises (resize -> jpeg, convert -> png).
#
# Run on macOS with Xcode command-line tools installed, from the repo:
#   bash apps/ios-frontend/ios/build-imagemagick.sh
#
# After it completes, in Xcode set the App target's HEADER_SEARCH_PATHS and LIBRARY_SEARCH_PATHS to
# the matching slice under vendor/im, add OTHER_LDFLAGS
#   -lMagickWand-7.Q16HDRI -lMagickCore-7.Q16HDRI -ljpeg -lpng16 -lz
# and add IMAGEMAGICK_LINKED to SWIFT_ACTIVE_COMPILATION_CONDITIONS to enable the runner.
set -euo pipefail

# Resolve paths relative to this script so no machine-specific absolute paths are baked in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_ROOT="$SCRIPT_DIR/App/vendor/im"
WORK="${TMPDIR:-/tmp}/photosphere-im-build"

IM_VERSION="7.1.1-43"
JPEG_URL="http://www.ijg.org/files/jpegsrc.v9e.tar.gz"
PNG_URL="https://download.sourceforge.net/libpng/libpng-1.6.43.tar.gz"
# zlib must be built from source for the target so ImageMagick's configure enables ZLIB_DELEGATE (and
# therefore PNG_DELEGATE): without a target zlib in the prefix the PNG coder is silently disabled.
ZLIB_URL="https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
IM_URL="https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IM_VERSION}.tar.gz"
MINVER=13.0

# Builds one slice (device or simulator) into $PREFIX for the given arch/sdk/host triple.
build_slice() {
  local slice="$1" arch="$2" sdk="$3" host="$4" minflag="$5"
  local prefix="$PREFIX_ROOT/$slice"
  local work="$WORK/$slice"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  export CC; CC="$(xcrun --sdk "$sdk" -f clang)"
  export CXX; CXX="$(xcrun --sdk "$sdk" -f clang++)"
  export RANLIB; RANLIB="$(xcrun --sdk "$sdk" -f ranlib)"
  export AR; AR="$(xcrun --sdk "$sdk" -f ar)"
  local flags="-arch $arch -isysroot $sysroot $minflag"
  export CFLAGS="$flags -I$prefix/include"
  export CPPFLAGS="$flags -I$prefix/include"
  export CXXFLAGS="$flags -I$prefix/include"
  export LDFLAGS="$flags -L$prefix/lib"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

  rm -rf "$work"; mkdir -p "$work" "$prefix"
  cd "$work"

  echo "==== [$slice] downloading sources ===="
  curl -fL --retry 3 -o zlib.tar.gz "$ZLIB_URL"
  curl -fL --retry 3 -o jpeg.tar.gz "$JPEG_URL"
  curl -fL --retry 3 -o png.tar.gz  "$PNG_URL"
  curl -fL --retry 3 -o im.tar.gz   "$IM_URL"

  # zlib first: libpng and ImageMagick's PNG/ZLIB delegates link against the target zlib in the prefix.
  # zlib uses its own (non-autoconf) configure driven by CC/CFLAGS/CHOST from the exported environment.
  echo "==== [$slice] zlib ===="
  mkdir -p zlib && tar xzf zlib.tar.gz -C zlib --strip-components=1
  ( cd zlib && CHOST="$host" ./configure --prefix="$prefix" --static >/dev/null
    make -j2 >/dev/null && make install >/dev/null )

  echo "==== [$slice] libjpeg ===="
  mkdir -p jpeg && tar xzf jpeg.tar.gz -C jpeg --strip-components=1
  ( cd jpeg && ./configure --host="$host" --prefix="$prefix" --disable-shared --enable-static >/dev/null
    make -j2 >/dev/null && make install >/dev/null )

  echo "==== [$slice] libpng ===="
  mkdir -p png && tar xzf png.tar.gz -C png --strip-components=1
  ( cd png && ./configure --host="$host" --prefix="$prefix" --disable-shared --enable-static >/dev/null
    make -j2 >/dev/null && make install >/dev/null )

  echo "==== [$slice] ImageMagick ===="
  mkdir -p im && tar xzf im.tar.gz -C im --strip-components=1
  ( cd im && ./configure --host="$host" --prefix="$prefix" \
      ac_cv_header_sys_random_h=no ac_cv_func_getentropy=no \
      --disable-shared --enable-static \
      --disable-openmp --disable-opencl --without-threads \
      --without-magick-plus-plus --disable-docs --disable-installed \
      --with-quantum-depth=16 --enable-hdri --without-x \
      --with-jpeg --with-png --with-zlib \
      --without-tiff --without-webp --without-heic --without-freetype \
      --without-fontconfig --without-xml --without-bzlib --without-lzma \
      --without-fftw --without-dps --without-djvu --without-openexr \
      --without-jbig --without-jp2 --without-lcms --without-openjp2 \
      --without-pango --without-raqm --without-raw --without-wmf \
      --without-jxl --without-lqr --without-flif --without-fpx \
      --without-gslib --without-gvc --without-rsvg --without-zstd \
      --without-libzip >/dev/null
    make -j2 >/dev/null && make install >/dev/null )

  echo "==== [$slice] DONE -> $prefix/lib ===="
  ls -1 "$prefix/lib"/*.a
}

# Device slice: arm64 for real hardware (required for release).
build_slice device arm64 iphoneos arm-apple-darwin "-miphoneos-version-min=$MINVER"
# Simulator slice: match the host arch so the built libs link into the simulator app running on this
# machine (arm64 sim on Apple Silicon, x86_64 sim on Intel). The host triple must match the arch or
# ImageMagick's configure cross-compile detection produces the wrong slice.
SIM_ARCH="$(uname -m)"
if [ "$SIM_ARCH" = "x86_64" ]; then
  SIM_HOST="x86_64-apple-darwin"
else
  SIM_HOST="arm-apple-darwin"
fi
build_slice sim "$SIM_ARCH" iphonesimulator "$SIM_HOST" "-mios-simulator-version-min=$MINVER"

echo "==== ALL SLICES DONE ===="
