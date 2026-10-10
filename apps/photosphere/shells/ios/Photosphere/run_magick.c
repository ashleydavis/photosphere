// In-process ImageMagick entry point for iOS, calling ImageMagick's own command-line dispatcher (what the `magick` binary does
// internally) so the same argv the desktop CLI uses runs here. Stdout is redirected to a capture file around the call so identify /
// info: / histogram text is captured reliably, then the Swift caller reads the file.

#include "run_magick.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <MagickWand/MagickWand.h>

int run_magick(int argc, char **argv, const char *capturePath) {
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    int fd = open(capturePath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd != -1) {
        dup2(fd, STDOUT_FILENO);
    }

    MagickWandGenesis();
    ImageInfo *image_info = AcquireImageInfo();
    ExceptionInfo *exception = AcquireExceptionInfo();

    // The unified `magick` dispatcher treats argv[1] as an input FILENAME, so it
    // cannot run the identify subcommand. Route "magick identify ..." to
    // IdentifyImageCommand directly (argv[0] becomes "identify").
    MagickCommand command = MagickImageCommand;
    int cmd_argc = argc;
    char **cmd_argv = argv;
    if (argc > 1 && strcmp(argv[1], "identify") == 0) {
        command = IdentifyImageCommand;
        cmd_argc = argc - 1;
        cmd_argv = argv + 1;
    }

    MagickBooleanType ok = MagickCommandGenesis(
        image_info, command, cmd_argc, cmd_argv, NULL, exception);
    int code = (ok == MagickTrue) ? 0 : 1;
    image_info = DestroyImageInfo(image_info);
    exception = DestroyExceptionInfo(exception);
    MagickWandTerminus();

    fflush(stdout);
    if (fd != -1) {
        dup2(saved, STDOUT_FILENO);
        close(fd);
    }
    close(saved);
    return code;
}
