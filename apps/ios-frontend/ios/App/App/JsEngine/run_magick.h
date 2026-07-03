#ifndef RUN_MAGICK_H
#define RUN_MAGICK_H

// Runs an argv exactly as the `magick` CLI would, in-process. argv[0] must be
// "magick". Text output from "-format ... info:" / "histogram:info:" / identify
// is captured by redirecting stdout to capturePath, which the Swift caller reads
// back. Returns 0 on success, 1 on dispatcher failure, -1 if ImageMagick is not
// linked into the target.
int run_magick(int argc, char **argv, const char *capturePath);

#endif /* RUN_MAGICK_H */
