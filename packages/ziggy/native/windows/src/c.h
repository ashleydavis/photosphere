// Zig defines _FORTIFY_SOURCE for an optimized build, which makes the mingw headers define inline string functions that
// the translation of this file to Zig cannot compile. The shell calls none of them.
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <objbase.h>
#include "WebView2.h"
#include "ziggy.h"
