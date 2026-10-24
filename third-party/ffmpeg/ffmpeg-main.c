// Builds fftools/ffmpeg.c with its main function named ffmpeg_main, so that it can be linked into a program that has a main of its own.
// On Windows fftools/cmdutils.h undoes a -Dmain=... given on the command line (`#undef main`), so it is included here first, where its
// include guard keeps it from being read again, and main is renamed after it.
#include "fftools/cmdutils.h"
#define main ffmpeg_main
#include "fftools/ffmpeg.c"
#undef main

// Runs ffmpeg_main as a run of its own on the calling thread, with state of its own (fftools/fftools_state.h, which
// fftools-per-run-state.patch adds), so that runs on several threads at once share nothing. `log_context` is handed back to the
// program's log callback through the run. Puts ffmpeg's exit code in `exit_code` and returns 0, or returns a negative AVERROR when the
// run could not be started.
int ffmpeg_run(int argc, char **argv, void *log_context, int *exit_code)
{
    int ret = fftools_run_begin(&ffmpeg_defaults, sizeof(ffmpeg_defaults), log_context);
    if (ret < 0)
        return ret;
    ffmpeg_state_init(fftools_run());
    *exit_code = ffmpeg_main(argc, argv);
    fftools_run_end();
    return ret;
}

// The value the calling thread's run of ffmpeg or ffprobe was given for the log callback, or NULL on a thread that runs neither (a
// thread of the libraries' own).
void *fftools_current_log_context(void)
{
    FFToolsRun *run = fftools_current_run();
    return run ? run->log_context : NULL;
}

// The log level the calling thread's run set (-loglevel), which starts at libavutil's own default. Called only on a thread that
// runs ffmpeg or ffprobe.
int fftools_current_log_level(void)
{
    return fftools_run()->log_level;
}

// Hands a message of FFmpeg's log to the log callback one of the run's own options set (help, -report, -show_log), and says
// whether there was one.
int fftools_forward_log(void *avcl, int level, const char *fmt, va_list vl)
{
    FFToolsRun *run = fftools_current_run();
    if (!run || !run->log_callback)
        return 0;
    run->log_callback(avcl, level, fmt, vl);
    return 1;
}
