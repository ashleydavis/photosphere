// Builds fftools/ffmpeg.c with its main function named ffmpeg_main, so that it can be linked into a program that has a main of its own.
// On Windows fftools/cmdutils.h undoes a -Dmain=... given on the command line (`#undef main`), so it is included here first, where its
// include guard keeps it from being read again, and main is renamed after it.
#include "fftools/cmdutils.h"
#define main ffmpeg_main
#include "fftools/ffmpeg.c"
