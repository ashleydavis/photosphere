// Builds fftools/ffmpeg.c with its main function named ffmpeg_main, so that it can be linked into a program that has a main of its own.
// On Windows fftools/cmdutils.h undoes a -Dmain=... given on the command line (`#undef main`), so it is included here first, where its
// include guard keeps it from being read again, and main is renamed after it.
#include "fftools/cmdutils.h"
#define main ffmpeg_main
#include "fftools/ffmpeg.c"

// Asks a running ffmpeg_main to stop, the way one SIGTERM does (sigterm_handler in fftools/ffmpeg.c): the transcode loop and
// decode_interrupt_cb see the signal count and end the run, which then returns a non-zero exit code. The program's own stop
// flags are static to fftools/ffmpeg.c, so they are set here, in the same translation unit, rather than from Zig.
void ffmpeg_request_stop(void)
{
    received_sigterm = SIGTERM;
    received_nb_signals++;
}

// Clears what ffmpeg_request_stop set, and the mark that a run reached its transcode loop, so the next run starts as the first
// run of a fresh program does. Called after every run.
void ffmpeg_reset_stop(void)
{
    received_sigterm = 0;
    received_nb_signals = 0;
    atomic_store(&transcode_init_done, 0);
}
