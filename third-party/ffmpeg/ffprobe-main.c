// Builds fftools/ffprobe.c with its main function named ffprobe_main, so that it can be linked into a program that has a main of its own.
// On Windows fftools/cmdutils.h undoes a -Dmain=... given on the command line (`#undef main`), so it is included here first, where its
// include guard keeps it from being read again, and main is renamed after it.
#include "fftools/cmdutils.h"
#define main ffprobe_main
#include "fftools/ffprobe.c"
#undef main

// Runs ffprobe_main as a run of its own on the calling thread, with state of its own (fftools/fftools_state.h, which
// fftools-per-run-state.patch adds), so that runs on several threads at once share nothing. `log_context` is handed back to the
// program's log callback through the run. Puts ffprobe's exit code in `exit_code` and returns 0, or returns a negative AVERROR when the
// run could not be started.
int ffprobe_run(int argc, char **argv, void *log_context, int *exit_code)
{
    int ret = fftools_run_begin(&ffprobe_defaults, sizeof(ffprobe_defaults), log_context);
    if (ret < 0)
        return ret;
    *exit_code = ffprobe_main(argc, argv);
    fftools_run_end();
    return ret;
}
