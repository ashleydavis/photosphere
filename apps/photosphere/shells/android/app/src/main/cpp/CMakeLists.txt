cmake_minimum_required(VERSION 3.22.1)
project(run_magick C)

# In-process ImageMagick shim. Compiles run_magick.c against the ImageMagick 7 headers and links it to the prebuilt libMagickWand and
# libMagickCore shared libraries. The headers and the libraries are not committed: scripts/fetch-mobile-media-tools.sh fetches them
# into git-ignored directories, and app/build.gradle passes where as IMAGEMAGICK_DIR (the headers) and IMAGEMAGICK_LIBS_DIR (the
# libraries, one directory per ABI).

if(NOT DEFINED IMAGEMAGICK_DIR OR NOT DEFINED IMAGEMAGICK_LIBS_DIR)
  message(FATAL_ERROR "IMAGEMAGICK_DIR and IMAGEMAGICK_LIBS_DIR must be set (see app/build.gradle).")
endif()

# The generated config headers (magick-baseconfig.h, version.h) are per ABI. Map the Android ABI to the matching configs/ overlay; it
# must precede the common include dir so MagickCore/magick-baseconfig.h resolves to this ABI.
if(ANDROID_ABI STREQUAL "x86_64")
  set(IM_CONFIG ${IMAGEMAGICK_DIR}/configs/x86-64)
elseif(ANDROID_ABI STREQUAL "arm64-v8a")
  set(IM_CONFIG ${IMAGEMAGICK_DIR}/configs/arm64)
else()
  message(FATAL_ERROR "No ImageMagick config overlay for ABI ${ANDROID_ABI}")
endif()

set(JNILIBS ${IMAGEMAGICK_LIBS_DIR}/${ANDROID_ABI})
add_library(magickcore SHARED IMPORTED)
set_target_properties(magickcore PROPERTIES IMPORTED_LOCATION ${JNILIBS}/libmagickcore-7.so)
add_library(magickwand SHARED IMPORTED)
set_target_properties(magickwand PROPERTIES IMPORTED_LOCATION ${JNILIBS}/libmagickwand-7.so)

add_library(run_magick SHARED run_magick.c)
target_include_directories(run_magick PRIVATE ${IM_CONFIG} ${IMAGEMAGICK_DIR}/include)

# Quantum depth and HDRI must be set via -D at compile time (the generated config header names them *_OBSOLETE_IN_H and leaves the
# makefile to define them). This build is Q16 HDRI, matching the prebuilt .so.
target_compile_definitions(run_magick PRIVATE
  MAGICKCORE_QUANTUM_DEPTH=16
  MAGICKCORE_HDRI_ENABLE=1)

target_link_libraries(run_magick magickwand magickcore log)

# 16KB page alignment so the shim loads on Android 15/16 (API 35/36) devices.
target_link_options(run_magick PRIVATE "-Wl,-z,max-page-size=16384")
