# update-ffmpeg.sh

Takes a given upstream FFmpeg version's source into `third-party/ffmpeg/vendor/ffmpeg` and applies `fftools-per-run-state.patch` to it. Run it when you want a newer FFmpeg; nothing else changes the vendored source.

```
third-party/ffmpeg/update-ffmpeg.sh <version>
```

- `<version>`: an FFmpeg release, for example `9.0.2`. The source is downloaded from `https://ffmpeg.org/releases/ffmpeg-<version>.tar.xz`.

What it does:

- Unpacks the release into `third-party/ffmpeg/vendor/ffmpeg`, leaving out the reference output of FFmpeg's own tests, the presets and the player. The rest of the tests directory stays because FFmpeg's top level Makefile includes it, and the file lists of the Zig build are read from that Makefile.
- Writes `third-party/ffmpeg/vendor/ffmpeg/VENDORED_VERSION` with the version and the address it came from.
- Moves the copy that was there to `third-party/ffmpeg/vendor/ffmpeg.previous` rather than deleting it. Compare the two, then delete the old one yourself.
- Applies `third-party/ffmpeg/fftools-per-run-state.patch` with `patch -p1` in the new copy. When the new version's command line programs have changed so that the patch no longer applies, the script fails, naming the files `patch` could not change: carry the changes over to the new source by hand, as described below, and write the patch again as a diff of the release's `fftools` against the changed one.

After taking a new version, make the generated headers and file lists again for every target (`third-party/ffmpeg/generate-config.md`) and build and test the library (`zig build` in `third-party/ffmpeg`, then the media-tools tests of Photosphere). The download and unpacking is in `third-party/ffmpeg/vendor-library.sh`.

## What the patch is for

Photosphere runs FFmpeg's `ffmpeg` and `ffprobe` command line programs inside its own process (through `ffmpeg-main.c` and `ffprobe-main.c`), on whichever worker thread a task needs them, and several workers run them at once. Upstream, the programs keep their state in variables of the whole process, and `ffmpeg` starts threads of its own (the scheduler's, in `fftools/ffmpeg_sched.c`) that read that state, so two commands at once would overwrite each other's state. ffmpeg-kit (`https://github.com/arthenica/ffmpeg-kit`) made the variables thread-local for FFmpeg 6 for the same reason; since FFmpeg 7 a thread-local variable alone is not enough, because the scheduler's threads must see the state of the run that started them.

The patch:

- Moves every variable the programs kept for the whole process, including the static variables inside functions and the signal flags (`received_sigterm`, `received_nb_signals`), into the state of one run: `FFmpegState` (`fftools/ffmpeg.h`), `FFprobeState` (`fftools/ffprobe.c`) and what the two share, `FFToolsCommon` (`fftools/fftools_state.h`, which the patch adds). Each thread reaches its run through a thread-local pointer, and the scheduler gives each thread it starts the run that started it, so the threads of one run share its state, as upstream's threads share the variables, and no other run sees it.
- Keeps the programs' option tables: an option that set a variable points into the state's defaults (`ffmpeg_defaults`, `ffprobe_defaults`, `fftools_common_defaults`), and `write_option` writes the same field of the run's state.
- Gives the interrupt callback the run as its context, because the libraries may call it on a thread of their own.
- Keeps the log level, flags and callback the programs set as the run's, in place of libavutil's for the whole process. `ffmpeg-main.c` lets the program's own log callback read them back.
- Installs no signal or console control handler, does not change stderr's buffering or the search path of libraries, and refuses `-cpuflags`, `-cpucount` and `-max_alloc`, because each of those is a setting of the whole process that other runs would share.
