// The Windows SDK has no ssize_t, which ImageMagick's headers use, and configure, run for the MSVC ABI, can only say so: it writes
// _magickcore_ssize_t as int, which no header maps to ssize_t, and which would be too narrow on 64-bit Windows anyway. ImageMagick's own
// Visual Studio build gets it from its project's headers, which are not vendored, so the build gives every ImageMagick source this header
// first, with the SDK's own signed size type.
#include <basetsd.h>
typedef SSIZE_T ssize_t;
