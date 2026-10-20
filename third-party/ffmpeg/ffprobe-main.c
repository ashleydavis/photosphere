// Builds fftools/ffprobe.c with its main function named ffprobe_main, so that it can be linked into a program that has a main of its own.
// On Windows fftools/cmdutils.h undoes a -Dmain=... given on the command line (`#undef main`), so it is included here first, where its
// include guard keeps it from being read again, and main is renamed after it.
#include "fftools/cmdutils.h"
#define main ffprobe_main
#include "fftools/ffprobe.c"
