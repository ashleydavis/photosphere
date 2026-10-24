/*
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/*
 * Added by fftools-per-run-state.patch, for a program that runs ffmpeg and ffprobe in its own process, on several threads at once.
 *
 * Everything the command line programs kept in variables of the whole process is the state of one run: an FFToolsRun, holding the
 * state the two programs share (FFToolsCommon) and the program's own (FFmpegState in ffmpeg.h, FFprobeState in ffprobe.c). The run
 * is made by fftools_run_begin on the thread that runs the program and freed by fftools_run_end, and each thread reaches its run
 * through a thread-local pointer, which the threads the run starts are given (task_wrapper in ffmpeg_sched.c). So the threads of one
 * run share its state, as the program's threads share its variables, and the threads of another run never see it.
 *
 * What a run would set for the whole process through the libraries is the run's too: its log level, flags and callback (the
 * fftools_log_set_* functions, which the programs call in place of av_log_set_*), which the program that runs them reads back with
 * fftools_current_run from its own log callback.
 */

#ifndef FFTOOLS_FFTOOLS_STATE_H
#define FFTOOLS_FFTOOLS_STATE_H

#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>

#include "libavutil/dict.h"
#include "libavutil/thread.h"

/* A log callback (av_log_set_callback's). */
typedef void (*FFToolsLogCallback)(void *avcl, int level, const char *fmt, va_list vl);

/* The state the two programs share, from cmdutils.c, opt_common.c, graph/graphprint.c and resources/resman.c. */
typedef struct FFToolsCommon {
    AVDictionary *sws_dict;
    AVDictionary *swr_opts;
    AVDictionary *format_opts;
    AVDictionary *codec_opts;
    int hide_banner;

    // opt_common.c
    FILE *report_file;
    int report_file_level;
    int warned_cfg;
    int report_print_prefix;

    // graph/graphprint.c
    atomic_int prefix_num;

    // resources/resman.c
    AVMutex resman_mutex;
    AVDictionary *resman_resource_dic;
} FFToolsCommon;

/* What the shared state of a run starts as. The options that set a field point into this (see fftools_option_target). */
extern const FFToolsCommon fftools_common_defaults;

/* One run of ffmpeg or ffprobe. */
typedef struct FFToolsRun {
    FFToolsCommon common;

    // The program's own state, and what it starts as, which the program's options point into.
    void *program;
    const void *program_defaults;
    size_t program_size;

    // The log level, flags and callback the run set; the level starts at libavutil's own default, and the callback is NULL unless
    // one of the programs' options set one of their own (help, -report, -show_log).
    int log_level;
    int log_flags;
    FFToolsLogCallback log_callback;

    // The value the program that runs ffmpeg or ffprobe gave fftools_run_begin, for its log callback.
    void *log_context;
} FFToolsRun;

/* The calling thread's run. Aborts on a thread that runs neither program. */
FFToolsRun *fftools_run(void);

/* The calling thread's run, or NULL on a thread that runs neither program. */
FFToolsRun *fftools_current_run(void);

/* Gives the calling thread a run (a thread a run starts is given that run). */
void fftools_set_current_run(FFToolsRun *run);

/* Starts a run on the calling thread, with the program's state copied from its defaults. Returns 0 or a negative AVERROR. */
int fftools_run_begin(const void *program_defaults, size_t program_size, void *log_context);

/* Frees the calling thread's run, once its program has returned. */
void fftools_run_end(void);

/* The field of the run's state an option's address in the defaults stands for, or the address itself when it is in neither. */
void *fftools_option_target(void *dst_ptr);

/* The run's log level, flags and callback, which the programs set in place of libavutil's of the whole process. */
void fftools_log_set_level(int level);
int fftools_log_get_level(void);
void fftools_log_set_flags(int flags);
int fftools_log_get_flags(void);
void fftools_log_set_callback(FFToolsLogCallback callback);

/* The calling thread's run's shared state. */
#define FFTOOLS_COMMON(name) (fftools_run()->common.name)

#endif /* FFTOOLS_FFTOOLS_STATE_H */
