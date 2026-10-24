/*
 * Copyright (c) 2000-2003 Fabrice Bellard
 *
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

/**
 * @file
 * multimedia converter based on the FFmpeg libraries
 */

#include "config.h"

#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if HAVE_IO_H
#include <io.h>
#endif
#if HAVE_UNISTD_H
#include <unistd.h>
#endif

#if HAVE_SYS_RESOURCE_H
#include <sys/time.h>
#include <sys/types.h>
#include <sys/resource.h>
#elif HAVE_GETPROCESSTIMES
#include <windows.h>
#endif
#if HAVE_GETPROCESSMEMORYINFO
#include <windows.h>
#include <psapi.h>
#endif
#if HAVE_SETCONSOLECTRLHANDLER
#include <windows.h>
#endif

#if HAVE_SYS_SELECT_H
#include <sys/select.h>
#endif

#if HAVE_TERMIOS_H
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <termios.h>
#elif HAVE_KBHIT
#include <conio.h>
#endif

#include "libavutil/bprint.h"
#include "libavutil/dict.h"
#include "libavutil/mem.h"
#include "libavutil/time.h"

#include "libavformat/avformat.h"

#include "libavdevice/avdevice.h"

#include "cmdutils.h"
#if CONFIG_MEDIACODEC
#include "compat/android/binder.h"
#endif
#include "ffmpeg.h"
#include "ffmpeg_sched.h"
#include "ffmpeg_utils.h"
#include "graph/graphprint.h"

const char program_name[] = "ffmpeg";
const int program_birth_year = 2000;

static BenchmarkTimeStamps get_benchmark_time_stamps(void);
static int64_t getmaxrss(void);

static void term_exit_sigsafe(void)
{
#if HAVE_TERMIOS_H
    if(FFMPEG_STATE(restore_tty))
        tcsetattr (0, TCSANOW, &FFMPEG_STATE(oldtty));
#endif
}

void term_exit(void)
{
    av_log(NULL, AV_LOG_QUIET, "%s", "");
    term_exit_sigsafe();
}

/* Patched (fftools-per-run-state.patch): ffmpeg runs inside a program that may run several at once on its threads, and the
 * handling of signals belongs to the whole process, so ffmpeg installs no signal or console control handler of its own. */
void term_init(void)
{
#if HAVE_TERMIOS_H
    if (FFMPEG_STATE(stdin_interaction)) {
        struct termios tty;
        if (tcgetattr (0, &tty) == 0) {
            FFMPEG_STATE(oldtty) = tty;
            FFMPEG_STATE(restore_tty) = 1;

            tty.c_iflag &= ~(IGNBRK|BRKINT|PARMRK|ISTRIP
                             |INLCR|IGNCR|ICRNL|IXON);
            tty.c_oflag |= OPOST;
            tty.c_lflag &= ~(ECHO|ECHONL|ICANON|IEXTEN);
            tty.c_cflag &= ~(CSIZE|PARENB);
            tty.c_cflag |= CS8;
            tty.c_cc[VMIN] = 1;
            tty.c_cc[VTIME] = 0;

            tcsetattr (0, TCSANOW, &tty);
        }
    }
#endif
}

/* read a key without blocking */
static int read_key(void)
{
#if HAVE_TERMIOS_H
    int n = 1;
    struct timeval tv;
    fd_set rfds;

    FD_ZERO(&rfds);
    FD_SET(0, &rfds);
    tv.tv_sec = 0;
    tv.tv_usec = 0;
    n = select(1, &rfds, NULL, NULL, &tv);
    if (n > 0) {
        unsigned char ch;
        n = read(0, &ch, 1);
        if (n == 1)
            return ch;

        return n;
    }
#elif HAVE_KBHIT
#    if HAVE_PEEKNAMEDPIPE && HAVE_GETSTDHANDLE
    DWORD dw, nchars;
    if(!FFMPEG_STATE(read_key_input_handle)){
        FFMPEG_STATE(read_key_input_handle) = GetStdHandle(STD_INPUT_HANDLE);
        FFMPEG_STATE(read_key_is_pipe) = !GetConsoleMode(FFMPEG_STATE(read_key_input_handle), &dw);
    }

    if (FFMPEG_STATE(read_key_is_pipe)) {
        /* When running under a GUI, you will end here. */
        if (!PeekNamedPipe(FFMPEG_STATE(read_key_input_handle), NULL, 0, NULL, &nchars, NULL)) {
            // input pipe may have been closed by the program that ran ffmpeg
            return -1;
        }
        //Read it
        if(nchars != 0) {
            unsigned char ch;
            if (read(0, &ch, 1) == 1)
                return ch;
            return 0;
        }else{
            return -1;
        }
    }
#    endif
    if(kbhit())
        return(getch());
#endif
    return -1;
}

/* Patched: the run's state is the callback's context, because the libraries may call it on a thread of their own. */
static int decode_interrupt_cb(void *ctx)
{
    FFmpegState *state = ((FFToolsRun *)ctx)->program;
    return state->received_nb_signals > atomic_load(&state->transcode_init_done);
}

/* Patched: the run's interrupt callback, with the run as its context. */
void ffmpeg_state_init(FFToolsRun *run)
{
    FFmpegState *state = run->program;
    state->int_cb = (AVIOInterruptCB){ decode_interrupt_cb, run };
}

static void ffmpeg_cleanup(int ret)
{
    if ((FFMPEG_STATE(print_graphs) || FFMPEG_STATE(print_graphs_file)) && FFMPEG_STATE(nb_output_files) > 0)
        print_filtergraphs(FFMPEG_STATE(filtergraphs), FFMPEG_STATE(nb_filtergraphs), FFMPEG_STATE(input_files), FFMPEG_STATE(nb_input_files), FFMPEG_STATE(output_files), FFMPEG_STATE(nb_output_files));

    if (FFMPEG_STATE(do_benchmark)) {
        int64_t maxrss = getmaxrss() / 1024;
        av_log(NULL, AV_LOG_INFO, "bench: maxrss=%"PRId64"KiB\n", maxrss);
    }

    for (int i = 0; i < FFMPEG_STATE(nb_filtergraphs); i++)
        fg_free(&FFMPEG_STATE(filtergraphs)[i]);
    av_freep(&FFMPEG_STATE(filtergraphs));

    for (int i = 0; i < FFMPEG_STATE(nb_output_files); i++)
        of_free(&FFMPEG_STATE(output_files)[i]);

    for (int i = 0; i < FFMPEG_STATE(nb_input_files); i++)
        ifile_close(&FFMPEG_STATE(input_files)[i]);

    for (int i = 0; i < FFMPEG_STATE(nb_decoders); i++)
        dec_free(&FFMPEG_STATE(decoders)[i]);
    av_freep(&FFMPEG_STATE(decoders));

    if (FFMPEG_STATE(vstats_file)) {
        if (fclose(FFMPEG_STATE(vstats_file)))
            av_log(NULL, AV_LOG_ERROR,
                   "Error closing vstats file, loss of information possible: %s\n",
                   av_err2str(AVERROR(errno)));
    }
    av_freep(&FFMPEG_STATE(vstats_filename));
    of_enc_stats_close();

    hw_device_free_all();

    av_freep(&FFMPEG_STATE(filter_nbthreads));

    av_freep(&FFMPEG_STATE(print_graphs_file));
    av_freep(&FFMPEG_STATE(print_graphs_format));

    av_freep(&FFMPEG_STATE(input_files));
    av_freep(&FFMPEG_STATE(output_files));

    uninit_opts();

    avformat_network_deinit();

    if (FFMPEG_STATE(received_sigterm)) {
        av_log(NULL, AV_LOG_INFO, "Exiting normally, received signal %d.\n",
               (int) FFMPEG_STATE(received_sigterm));
    } else if (ret && atomic_load(&FFMPEG_STATE(transcode_init_done))) {
        av_log(NULL, AV_LOG_INFO, "Conversion failed!\n");
    }
    term_exit();
    FFMPEG_STATE(ffmpeg_exited) = 1;
}

OutputStream *ost_iter(OutputStream *prev)
{
    int of_idx  = prev ? prev->file->index : 0;
    int ost_idx = prev ? prev->index + 1  : 0;

    for (; of_idx < FFMPEG_STATE(nb_output_files); of_idx++) {
        OutputFile *of = FFMPEG_STATE(output_files)[of_idx];
        if (ost_idx < of->nb_streams)
            return of->streams[ost_idx];

        ost_idx = 0;
    }

    return NULL;
}

InputStream *ist_iter(InputStream *prev)
{
    int if_idx  = prev ? prev->file->index : 0;
    int ist_idx = prev ? prev->index + 1  : 0;

    for (; if_idx < FFMPEG_STATE(nb_input_files); if_idx++) {
        InputFile *f = FFMPEG_STATE(input_files)[if_idx];
        if (ist_idx < f->nb_streams)
            return f->streams[ist_idx];

        ist_idx = 0;
    }

    return NULL;
}

static void frame_data_free(void *opaque, uint8_t *data)
{
    FrameData *fd = (FrameData *)data;

    av_frame_side_data_free(&fd->side_data, &fd->nb_side_data);
    avcodec_parameters_free(&fd->par_enc);

    av_free(data);
}

static int frame_data_ensure(AVBufferRef **dst, int writable)
{
    AVBufferRef *src = *dst;

    if (!src || (writable && !av_buffer_is_writable(src))) {
        FrameData *fd;

        fd = av_mallocz(sizeof(*fd));
        if (!fd)
            return AVERROR(ENOMEM);

        *dst = av_buffer_create((uint8_t *)fd, sizeof(*fd),
                                frame_data_free, NULL, 0);
        if (!*dst) {
            av_buffer_unref(&src);
            av_freep(&fd);
            return AVERROR(ENOMEM);
        }

        if (src) {
            const FrameData *fd_src = (const FrameData *)src->data;

            memcpy(fd, fd_src, sizeof(*fd));
            fd->par_enc = NULL;
            fd->side_data = NULL;
            fd->nb_side_data = 0;

            if (fd_src->par_enc) {
                int ret = 0;

                fd->par_enc = avcodec_parameters_alloc();
                ret = fd->par_enc ?
                      avcodec_parameters_copy(fd->par_enc, fd_src->par_enc) :
                      AVERROR(ENOMEM);
                if (ret < 0) {
                    av_buffer_unref(dst);
                    av_buffer_unref(&src);
                    return ret;
                }
            }

            if (fd_src->nb_side_data) {
                int ret = clone_side_data(&fd->side_data, &fd->nb_side_data,
                                          fd_src->side_data, fd_src->nb_side_data, 0);
                if (ret < 0) {
                    av_buffer_unref(dst);
                    av_buffer_unref(&src);
                    return ret;
                }
            }

            av_buffer_unref(&src);
        } else {
            fd->dec.frame_num = UINT64_MAX;
            fd->dec.pts       = AV_NOPTS_VALUE;

            for (unsigned i = 0; i < FF_ARRAY_ELEMS(fd->wallclock); i++)
                fd->wallclock[i] = INT64_MIN;
        }
    }

    return 0;
}

FrameData *frame_data(AVFrame *frame)
{
    int ret = frame_data_ensure(&frame->opaque_ref, 1);
    return ret < 0 ? NULL : (FrameData*)frame->opaque_ref->data;
}

const FrameData *frame_data_c(AVFrame *frame)
{
    int ret = frame_data_ensure(&frame->opaque_ref, 0);
    return ret < 0 ? NULL : (const FrameData*)frame->opaque_ref->data;
}

FrameData *packet_data(AVPacket *pkt)
{
    int ret = frame_data_ensure(&pkt->opaque_ref, 1);
    return ret < 0 ? NULL : (FrameData*)pkt->opaque_ref->data;
}

const FrameData *packet_data_c(AVPacket *pkt)
{
    int ret = frame_data_ensure(&pkt->opaque_ref, 0);
    return ret < 0 ? NULL : (const FrameData*)pkt->opaque_ref->data;
}

int check_avoptions_used(const AVDictionary *opts, const AVDictionary *opts_used,
                         void *logctx, int decode)
{
    const AVClass  *class = avcodec_get_class();
    const AVClass *fclass = avformat_get_class();

    const int flag = decode ? AV_OPT_FLAG_DECODING_PARAM :
                              AV_OPT_FLAG_ENCODING_PARAM;
    const AVDictionaryEntry *e = NULL;

    while ((e = av_dict_iterate(opts, e))) {
        const AVOption *option, *foption;
        char *optname, *p;

        if (av_dict_get(opts_used, e->key, NULL, 0))
            continue;

        optname = av_strdup(e->key);
        if (!optname)
            return AVERROR(ENOMEM);

        p = strchr(optname, ':');
        if (p)
            *p = 0;

        option = av_opt_find(&class, optname, NULL, 0,
                             AV_OPT_SEARCH_CHILDREN | AV_OPT_SEARCH_FAKE_OBJ);
        foption = av_opt_find(&fclass, optname, NULL, 0,
                              AV_OPT_SEARCH_CHILDREN | AV_OPT_SEARCH_FAKE_OBJ);
        av_freep(&optname);
        if (!option || foption)
            continue;

        if (!(option->flags & flag)) {
            av_log(logctx, AV_LOG_ERROR, "Codec AVOption %s (%s) is not a %s "
                   "option.\n", e->key, option->help ? option->help : "",
                   decode ? "decoding" : "encoding");
            return AVERROR(EINVAL);
        }

        av_log(logctx, AV_LOG_WARNING, "Codec AVOption %s (%s) has not been used "
               "for any stream. The most likely reason is either wrong type "
               "(e.g. a video option with no video streams) or that it is a "
               "private option of some decoder which was not actually used "
               "for any stream.\n", e->key, option->help ? option->help : "");
    }

    return 0;
}

void update_benchmark(const char *fmt, ...)
{
    if (FFMPEG_STATE(do_benchmark_all)) {
        BenchmarkTimeStamps t = get_benchmark_time_stamps();
        va_list va;
        char buf[1024];

        if (fmt) {
            va_start(va, fmt);
            vsnprintf(buf, sizeof(buf), fmt, va);
            va_end(va);
            av_log(NULL, AV_LOG_INFO,
                   "bench: %8" PRIu64 " user %8" PRIu64 " sys %8" PRIu64 " real %s \n",
                   t.user_usec - FFMPEG_STATE(current_time).user_usec,
                   t.sys_usec - FFMPEG_STATE(current_time).sys_usec,
                   t.real_usec - FFMPEG_STATE(current_time).real_usec, buf);
        }
        FFMPEG_STATE(current_time) = t;
    }
}

static void print_report(int is_last_report, int64_t timer_start, int64_t cur_time, int64_t pts)
{
    AVBPrint buf, buf_script;
    int64_t total_size = of_filesize(FFMPEG_STATE(output_files)[0]);
    int vid;
    double bitrate;
    double speed;
    uint64_t nb_frames_dup = 0, nb_frames_drop = 0;
    int mins, secs, ms, us;
    int64_t hours;
    const char *hours_sign;
    int ret;
    float t;

    if (!FFMPEG_STATE(print_stats) && !is_last_report && !FFMPEG_STATE(progress_avio))
        return;

    if (!is_last_report) {
        if (FFMPEG_STATE(report_last_time) == -1) {
            FFMPEG_STATE(report_last_time) = cur_time;
        }
        if (((cur_time - FFMPEG_STATE(report_last_time)) < FFMPEG_STATE(stats_period) && !FFMPEG_STATE(first_report)) ||
            (FFMPEG_STATE(first_report) && atomic_load(&FFMPEG_STATE(nb_output_dumped)) < FFMPEG_STATE(nb_output_files)))
            return;
        FFMPEG_STATE(report_last_time) = cur_time;
    }

    t = (cur_time-timer_start) / 1000000.0;

    vid = 0;
    av_bprint_init(&buf, 0, AV_BPRINT_SIZE_AUTOMATIC);
    av_bprint_init(&buf_script, 0, AV_BPRINT_SIZE_AUTOMATIC);

    for (OutputStream *ost = ost_iter(NULL); ost; ost = ost_iter(ost)) {
        const float q = ost->enc ? atomic_load(&ost->quality) / (float) FF_QP2LAMBDA : -1;

        if (vid && ost->type == AVMEDIA_TYPE_VIDEO) {
            av_bprintf(&buf, "q=%2.1f ", q);
            av_bprintf(&buf_script, "stream_%d_%d_q=%.1f\n",
                       ost->file->index, ost->index, q);
        }
        if (!vid && ost->type == AVMEDIA_TYPE_VIDEO) {
            float fps;
            uint64_t frame_number = atomic_load(&ost->packets_written);

            fps = t > 1 ? frame_number / t : 0;
            av_bprintf(&buf, "frame=%5"PRId64" fps=%3.*f q=%3.1f ",
                     frame_number, fps < 9.95, fps, q);
            av_bprintf(&buf_script, "frame=%"PRId64"\n", frame_number);
            av_bprintf(&buf_script, "fps=%.2f\n", fps);
            av_bprintf(&buf_script, "stream_%d_%d_q=%.1f\n",
                       ost->file->index, ost->index, q);
            if (is_last_report)
                av_bprintf(&buf, "L");

            if (ost->filter) {
                nb_frames_dup  = atomic_load(&ost->filter->nb_frames_dup);
                nb_frames_drop = atomic_load(&ost->filter->nb_frames_drop);
            }

            vid = 1;
        }
    }

    if (FFMPEG_STATE(copy_ts)) {
        if (FFMPEG_STATE(copy_ts_first_pts) == AV_NOPTS_VALUE && pts > 1)
            FFMPEG_STATE(copy_ts_first_pts) = pts;
        if (FFMPEG_STATE(copy_ts_first_pts) != AV_NOPTS_VALUE)
            pts -= FFMPEG_STATE(copy_ts_first_pts);
    }

    us    = FFABS64U(pts) % AV_TIME_BASE;
    secs  = FFABS64U(pts) / AV_TIME_BASE % 60;
    mins  = FFABS64U(pts) / AV_TIME_BASE / 60 % 60;
    hours = FFABS64U(pts) / AV_TIME_BASE / 3600;
    hours_sign = (pts < 0) ? "-" : "";

    bitrate = pts != AV_NOPTS_VALUE && pts && total_size >= 0 ? total_size * 8 / (pts / 1000.0) : -1;
    speed   = pts != AV_NOPTS_VALUE && t != 0.0 ? (double)pts / AV_TIME_BASE / t : -1;

    if (total_size < 0) av_bprintf(&buf, "size=N/A time=");
    else                av_bprintf(&buf, "size=%8.0fKiB time=", total_size / 1024.0);
    if (pts == AV_NOPTS_VALUE) {
        av_bprintf(&buf, "N/A ");
    } else {
        av_bprintf(&buf, "%s%02"PRId64":%02d:%02d.%02d ",
                   hours_sign, hours, mins, secs, (100 * us) / AV_TIME_BASE);
    }

    if (bitrate < 0) {
        av_bprintf(&buf, "bitrate=N/A");
        av_bprintf(&buf_script, "bitrate=N/A\n");
    }else{
        av_bprintf(&buf, "bitrate=%6.1fkbits/s", bitrate);
        av_bprintf(&buf_script, "bitrate=%6.1fkbits/s\n", bitrate);
    }

    if (total_size < 0) av_bprintf(&buf_script, "total_size=N/A\n");
    else                av_bprintf(&buf_script, "total_size=%"PRId64"\n", total_size);
    if (pts == AV_NOPTS_VALUE) {
        av_bprintf(&buf_script, "out_time_us=N/A\n");
        av_bprintf(&buf_script, "out_time_ms=N/A\n");
        av_bprintf(&buf_script, "out_time=N/A\n");
    } else {
        av_bprintf(&buf_script, "out_time_us=%"PRId64"\n", pts);
        av_bprintf(&buf_script, "out_time_ms=%"PRId64"\n", pts);
        av_bprintf(&buf_script, "out_time=%s%02"PRId64":%02d:%02d.%06d\n",
                   hours_sign, hours, mins, secs, us);
    }

    if (nb_frames_dup || nb_frames_drop)
        av_bprintf(&buf, " dup=%"PRId64" drop=%"PRId64, nb_frames_dup, nb_frames_drop);
    av_bprintf(&buf_script, "dup_frames=%"PRId64"\n", nb_frames_dup);
    av_bprintf(&buf_script, "drop_frames=%"PRId64"\n", nb_frames_drop);

    if (speed < 0) {
        av_bprintf(&buf, " speed=N/A");
        av_bprintf(&buf_script, "speed=N/A\n");
    } else {
        av_bprintf(&buf, " speed=%4.3gx", speed);
        av_bprintf(&buf_script, "speed=%4.3gx\n", speed);
    }

    secs = (int)t;
    ms = (int)((t - secs) * 1000);
    mins = secs / 60;
    secs %= 60;
    hours = mins / 60;
    mins %= 60;

    av_bprintf(&buf, " elapsed=%"PRId64":%02d:%02d.%02d", hours, mins, secs, ms / 10);

    if (FFMPEG_STATE(print_stats) || is_last_report) {
        const char end = is_last_report ? '\n' : '\r';
        if (FFMPEG_STATE(print_stats)==1 && AV_LOG_INFO > fftools_log_get_level()) {
            fprintf(stderr, "%s    %c", buf.str, end);
        } else
            av_log(NULL, AV_LOG_INFO, "%s    %c", buf.str, end);

        fflush(stderr);
    }
    av_bprint_finalize(&buf, NULL);

    if (FFMPEG_STATE(progress_avio)) {
        av_bprintf(&buf_script, "progress=%s\n",
                   is_last_report ? "end" : "continue");
        avio_write(FFMPEG_STATE(progress_avio), buf_script.str,
                   FFMIN(buf_script.len, buf_script.size - 1));
        avio_flush(FFMPEG_STATE(progress_avio));
        av_bprint_finalize(&buf_script, NULL);
        if (is_last_report) {
            if ((ret = avio_closep(&FFMPEG_STATE(progress_avio))) < 0)
                av_log(NULL, AV_LOG_ERROR,
                       "Error closing progress log, loss of information possible: %s\n", av_err2str(ret));
        }
    }

    FFMPEG_STATE(first_report) = 0;
}

static void print_stream_maps(void)
{
    av_log(NULL, AV_LOG_INFO, "Stream mapping:\n");
    for (InputStream *ist = ist_iter(NULL); ist; ist = ist_iter(ist)) {
        for (int j = 0; j < ist->nb_filters; j++) {
            if (!filtergraph_is_simple(ist->filters[j]->graph)) {
                av_log(NULL, AV_LOG_INFO, "  Stream #%d:%d (%s) -> %s",
                       ist->file->index, ist->index, ist->dec ? ist->dec->name : "?",
                       ist->filters[j]->name);
                if (FFMPEG_STATE(nb_filtergraphs) > 1)
                    av_log(NULL, AV_LOG_INFO, " (graph %d)", ist->filters[j]->graph->index);
                av_log(NULL, AV_LOG_INFO, "\n");
            }
        }
    }

    for (OutputStream *ost = ost_iter(NULL); ost; ost = ost_iter(ost)) {
        if (ost->attachment_filename) {
            /* an attached file */
            av_log(NULL, AV_LOG_INFO, "  File %s -> Stream #%d:%d\n",
                   ost->attachment_filename, ost->file->index, ost->index);
            continue;
        }

        if (ost->filter && !filtergraph_is_simple(ost->filter->graph)) {
            /* output from a complex graph */
            av_log(NULL, AV_LOG_INFO, "  %s", ost->filter->name);
            if (FFMPEG_STATE(nb_filtergraphs) > 1)
                av_log(NULL, AV_LOG_INFO, " (graph %d)", ost->filter->graph->index);

            av_log(NULL, AV_LOG_INFO, " -> Stream #%d:%d (%s)\n", ost->file->index,
                   ost->index, ost->enc->enc_ctx->codec->name);
            continue;
        }

        av_log(NULL, AV_LOG_INFO, "  Stream #%d:%d -> #%d:%d",
               ost->ist->file->index,
               ost->ist->index,
               ost->file->index,
               ost->index);
        if (ost->enc) {
            const AVCodec *in_codec    = ost->ist->dec;
            const AVCodec *out_codec   = ost->enc->enc_ctx->codec;
            const char *decoder_name   = "?";
            const char *in_codec_name  = "?";
            const char *encoder_name   = "?";
            const char *out_codec_name = "?";
            const AVCodecDescriptor *desc;

            if (in_codec) {
                decoder_name  = in_codec->name;
                desc = avcodec_descriptor_get(in_codec->id);
                if (desc)
                    in_codec_name = desc->name;
                if (!strcmp(decoder_name, in_codec_name))
                    decoder_name = "native";
            }

            if (out_codec) {
                encoder_name   = out_codec->name;
                desc = avcodec_descriptor_get(out_codec->id);
                if (desc)
                    out_codec_name = desc->name;
                if (!strcmp(encoder_name, out_codec_name))
                    encoder_name = "native";
            }

            av_log(NULL, AV_LOG_INFO, " (%s (%s) -> %s (%s))",
                   in_codec_name, decoder_name,
                   out_codec_name, encoder_name);
        } else
            av_log(NULL, AV_LOG_INFO, " (copy)");
        av_log(NULL, AV_LOG_INFO, "\n");
    }
}

static void set_tty_echo(int on)
{
#if HAVE_TERMIOS_H
    struct termios tty;
    if (tcgetattr(0, &tty) == 0) {
        if (on) tty.c_lflag |= ECHO;
        else    tty.c_lflag &= ~ECHO;
        tcsetattr(0, TCSANOW, &tty);
    }
#endif
}

static int check_keyboard_interaction(int64_t cur_time)
{
    int i, key;
    /* read_key() returns 0 on EOF */
    if (cur_time - FFMPEG_STATE(keyboard_last_time) >= 100000) {
        key =  read_key();
        FFMPEG_STATE(keyboard_last_time) = cur_time;
    }else
        key = -1;
    if (key == 'q') {
        av_log(NULL, AV_LOG_INFO, "\n\n[q] command received. Exiting.\n\n");
        return AVERROR_EXIT;
    }
    if (key == '+') fftools_log_set_level(fftools_log_get_level()+10);
    if (key == '-') fftools_log_set_level(fftools_log_get_level()-10);
    if (key == 'c' || key == 'C'){
        char buf[4096], target[64], command[256], arg[256] = {0};
        double time;
        int k, n = 0;
        fprintf(stderr, "\nEnter command: <target>|all <time>|-1 <command>[ <argument>]\n");
        i = 0;
        set_tty_echo(1);
        while ((k = read_key()) != '\n' && k != '\r' && i < sizeof(buf)-1)
            if (k > 0)
                buf[i++] = k;
        buf[i] = 0;
        set_tty_echo(0);
        fprintf(stderr, "\n");
        if (k > 0 &&
            (n = sscanf(buf, "%63[^ ] %lf %255[^ ] %255[^\n]", target, &time, command, arg)) >= 3) {
            av_log(NULL, AV_LOG_DEBUG, "Processing command target:%s time:%f command:%s arg:%s",
                   target, time, command, arg);
            for (OutputStream *ost = ost_iter(NULL); ost; ost = ost_iter(ost)) {
                if (ost->fg_simple)
                    fg_send_command(ost->fg_simple, time, target, command, arg,
                                    key == 'C');
            }
            for (i = 0; i < FFMPEG_STATE(nb_filtergraphs); i++)
                fg_send_command(FFMPEG_STATE(filtergraphs)[i], time, target, command, arg,
                                key == 'C');
        } else {
            av_log(NULL, AV_LOG_ERROR,
                   "Parse error, at least 3 arguments were expected, "
                   "only %d given in string '%s'\n", n, buf);
        }
    }
    if (key == '?'){
        fprintf(stderr, "key    function\n"
                        "?      show this help\n"
                        "+      increase verbosity\n"
                        "-      decrease verbosity\n"
                        "c      Send command to first matching filter supporting it\n"
                        "C      Send/Queue command to all matching filters\n"
                        "h      dump packets/hex press to cycle through the 3 states\n"
                        "q      quit\n"
                        "s      Show QP histogram\n"
        );
    }
    return 0;
}

/*
 * The following code is the main loop of the file converter
 */
static int transcode(Scheduler *sch)
{
    int ret = 0;
    int64_t timer_start, transcode_ts = 0;

    print_stream_maps();

    atomic_store(&FFMPEG_STATE(transcode_init_done), 1);

    ret = sch_start(sch);
    if (ret < 0)
        return ret;

    if (FFMPEG_STATE(stdin_interaction)) {
        av_log(NULL, AV_LOG_INFO, "Press [q] to stop, [?] for help\n");
    }

    timer_start = av_gettime_relative();

    while (!sch_wait(sch, FFMPEG_STATE(stats_period), &transcode_ts)) {
        int64_t cur_time= av_gettime_relative();

        if (FFMPEG_STATE(received_nb_signals))
            break;

        /* if 'q' pressed, exits */
        if (FFMPEG_STATE(stdin_interaction))
            if (check_keyboard_interaction(cur_time) < 0)
                break;

        /* dump report by using the output first video and audio streams */
        print_report(0, timer_start, cur_time, transcode_ts);
    }

    ret = sch_stop(sch, &transcode_ts);

    /* write the trailer if needed */
    for (int i = 0; i < FFMPEG_STATE(nb_output_files); i++) {
        int err = of_write_trailer(FFMPEG_STATE(output_files)[i]);
        ret = err_merge(ret, err);
    }

    term_exit();

    /* dump report by using the first video and audio streams */
    print_report(1, timer_start, av_gettime_relative(), transcode_ts);

    return ret;
}

static BenchmarkTimeStamps get_benchmark_time_stamps(void)
{
    BenchmarkTimeStamps time_stamps = { av_gettime_relative() };
#if HAVE_GETRUSAGE
    struct rusage rusage;

    getrusage(RUSAGE_SELF, &rusage);
    time_stamps.user_usec =
        (rusage.ru_utime.tv_sec * 1000000LL) + rusage.ru_utime.tv_usec;
    time_stamps.sys_usec =
        (rusage.ru_stime.tv_sec * 1000000LL) + rusage.ru_stime.tv_usec;
#elif HAVE_GETPROCESSTIMES
    HANDLE proc;
    FILETIME c, e, k, u;
    proc = GetCurrentProcess();
    GetProcessTimes(proc, &c, &e, &k, &u);
    time_stamps.user_usec =
        ((int64_t)u.dwHighDateTime << 32 | u.dwLowDateTime) / 10;
    time_stamps.sys_usec =
        ((int64_t)k.dwHighDateTime << 32 | k.dwLowDateTime) / 10;
#else
    time_stamps.user_usec = time_stamps.sys_usec = 0;
#endif
    return time_stamps;
}

static int64_t getmaxrss(void)
{
#if HAVE_GETRUSAGE && HAVE_STRUCT_RUSAGE_RU_MAXRSS
    struct rusage rusage;
    getrusage(RUSAGE_SELF, &rusage);
    return (int64_t)rusage.ru_maxrss * 1024;
#elif HAVE_GETPROCESSMEMORYINFO
    HANDLE proc;
    PROCESS_MEMORY_COUNTERS memcounters;
    proc = GetCurrentProcess();
    memcounters.cb = sizeof(memcounters);
    GetProcessMemoryInfo(proc, &memcounters, sizeof(memcounters));
    return memcounters.PeakPagefileUsage;
#else
    return 0;
#endif
}

int main(int argc, char **argv)
{
    Scheduler *sch = NULL;

    int ret;
    BenchmarkTimeStamps ti;

    /* Patched: the search path of libraries and the buffering of stderr belong to the whole process, which ffmpeg runs inside of,
     * so ffmpeg changes neither (init_dynload and setvbuf are not called). */
    fftools_log_set_flags(AV_LOG_SKIP_REPEATED);
    parse_loglevel(argc, argv, options);

#if CONFIG_AVDEVICE
    avdevice_register_all();
#endif
    avformat_network_init();

    show_banner(argc, argv, options);

    sch = sch_alloc();
    if (!sch) {
        ret = AVERROR(ENOMEM);
        goto finish;
    }

    /* parse options and open all input/output files */
    ret = ffmpeg_parse_options(argc, argv, sch);
    if (ret < 0)
        goto finish;

    if (FFMPEG_STATE(nb_output_files) <= 0 && FFMPEG_STATE(nb_input_files) == 0) {
        show_usage();
        av_log(NULL, AV_LOG_WARNING, "Use -h to get full help or, even better, run 'man %s'\n", program_name);
        ret = 1;
        goto finish;
    }

    if (FFMPEG_STATE(nb_output_files) <= 0) {
        av_log(NULL, AV_LOG_FATAL, "At least one output file must be specified\n");
        ret = 1;
        goto finish;
    }

#if CONFIG_MEDIACODEC
    android_binder_threadpool_init_if_required();
#endif

    FFMPEG_STATE(current_time) = ti = get_benchmark_time_stamps();
    ret = transcode(sch);
    if (ret >= 0 && FFMPEG_STATE(do_benchmark)) {
        int64_t utime, stime, rtime;
        FFMPEG_STATE(current_time) = get_benchmark_time_stamps();
        utime = FFMPEG_STATE(current_time).user_usec - ti.user_usec;
        stime = FFMPEG_STATE(current_time).sys_usec  - ti.sys_usec;
        rtime = FFMPEG_STATE(current_time).real_usec - ti.real_usec;
        av_log(NULL, AV_LOG_INFO,
               "bench: utime=%0.3fs stime=%0.3fs rtime=%0.3fs\n",
               utime / 1000000.0, stime / 1000000.0, rtime / 1000000.0);
    }

    ret = FFMPEG_STATE(received_nb_signals)                 ? 255 :
          (ret == FFMPEG_ERROR_RATE_EXCEEDED) ?  69 : ret;

finish:
    if (ret == AVERROR_EXIT)
        ret = 0;

    ffmpeg_cleanup(ret);

    sch_free(&sch);

    av_log(NULL, AV_LOG_VERBOSE, "\n");
    av_log(NULL, AV_LOG_VERBOSE, "Exiting with exit code %d\n", ret);

    return ret;
}
