// In-process ImageMagick entry point for Android. Mobile ImageMagick ships the
// C libraries (libMagickCore/libMagickWand) but no ready-made "run the magick
// CLI" call. This shim invokes ImageMagick's own command-line dispatcher in
// process (exactly what the `magick` binary does internally), so the SAME argv
// the desktop CLI uses runs here. The JNI wrapper marshals a Java String[] to
// char** and returns { exitCode, output } back to ImageMagickRunner.java.
//
// Text-producing operations (identify, EXIF, dominant colour, histogram) print
// to stdout. Rather than rely on MagickCommandGenesis's metadata out-param
// (which only captures `info:`-coder output and proved unreliable on device),
// the JNI wrapper redirects the process stdout to a capture file around the
// call and reads it back. File-producing operations (resize/convert/transform)
// write their output file directly and are read back by the Java side.

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <MagickWand/MagickWand.h>

// Runs an argv exactly as the `magick` CLI would, in-process. argv[0] must be
// "magick". The JNI wrapper passes NULL metadata and captures stdout instead.
// Returns 0 on success, 1 on failure.
static int run_magick(int argc, char **argv, char **metadata_out) {
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
        image_info, command, cmd_argc, cmd_argv, metadata_out, exception);
    int code = (ok == MagickTrue) ? 0 : 1;
    image_info = DestroyImageInfo(image_info);
    exception = DestroyExceptionInfo(exception);
    MagickWandTerminus();
    return code;
}

// Read an entire file into a newly malloc'd, NUL-terminated string (or NULL).
static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = NULL;
    if (n > 0) {
        buf = (char *) malloc((size_t) n + 1);
        if (buf != NULL) {
            size_t got = fread(buf, 1, (size_t) n, f);
            buf[got] = '\0';
        }
    }
    fclose(f);
    return buf;
}

// JNI bridge. jargv already includes "magick" as element 0 (added by the Java
// runner). capturePath is a writable file used to capture stdout text output.
// Returns Object[]{ Integer exitCode, String output }.
JNIEXPORT jobjectArray JNICALL
Java_au_com_codecapers_photosphere_jsengine_ImageMagickRunner_nativeMagick(JNIEnv *env, jobject thiz,
                                                                          jobjectArray jargv, jstring jCapturePath) {
    (void) thiz;
    jsize argc = (*env)->GetArrayLength(env, jargv);
    char **argv = (char **) calloc((size_t) argc + 1, sizeof(char *));
    for (jsize i = 0; i < argc; i++) {
        jstring s = (jstring) (*env)->GetObjectArrayElement(env, jargv, i);
        const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
        argv[i] = strdup(utf != NULL ? utf : "");
        (*env)->ReleaseStringUTFChars(env, s, utf);
        (*env)->DeleteLocalRef(env, s);
    }
    argv[argc] = NULL;

    const char *capturePath = (*env)->GetStringUTFChars(env, jCapturePath, NULL);

    // Redirect stdout to the capture file around the dispatcher call so that
    // identify / info: / histogram text is captured reliably.
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    int fd = open(capturePath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd != -1) {
        dup2(fd, STDOUT_FILENO);
    }

    int code = run_magick((int) argc, argv, NULL);

    fflush(stdout);
    if (fd != -1) {
        dup2(saved, STDOUT_FILENO);
        close(fd);
    }
    close(saved);

    char *captured = read_file(capturePath);
    (*env)->ReleaseStringUTFChars(env, jCapturePath, capturePath);

    jclass objClass = (*env)->FindClass(env, "java/lang/Object");
    jobjectArray result = (*env)->NewObjectArray(env, 2, objClass, NULL);

    jclass intClass = (*env)->FindClass(env, "java/lang/Integer");
    jmethodID intCtor = (*env)->GetMethodID(env, intClass, "<init>", "(I)V");
    jobject codeObj = (*env)->NewObject(env, intClass, intCtor, (jint) code);
    (*env)->SetObjectArrayElement(env, result, 0, codeObj);

    jstring outStr = (*env)->NewStringUTF(env, captured != NULL ? captured : "");
    (*env)->SetObjectArrayElement(env, result, 1, outStr);

    free(captured);
    for (jsize i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
    return result;
}
