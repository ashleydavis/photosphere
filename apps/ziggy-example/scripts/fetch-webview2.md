# fetch-webview2.sh

Downloads the pinned WebView2 SDK into `apps/ziggy-example/webview2-sdk/` (gitignored), verifying each download against a pinned sha256.

Run it as `bash apps/ziggy-example/scripts/fetch-webview2.sh`. It takes no arguments and can be run again safely: a download already present with the right hash is reused.

What it produces:

- `include/WebView2.h` and `include/WebView2EnvironmentOptions.h`, from the Microsoft.Web.WebView2 NuGet package. The shell translates `WebView2.h` to Zig with `zig translate-c`.
- `include/EventToken.h`. `WebView2.h` includes it, and Zig's bundled mingw headers do not have it. It is the unmodified `eventtoken.h` from the mingw-w64 project at a pinned commit, saved under the name the include expects.
- `x64/WebView2LoaderStatic.lib` and `arm64/WebView2LoaderStatic.lib`, the SDK's static loader, which the build links into the executable.

Where the pinned values come from: the version is one published on nuget.org. Both sha256 values were computed with `sha256sum` on the files as served (the `.nupkg` from `api.nuget.org`, the header from `raw.githubusercontent.com`) at the time of pinning. To update the pin, change the version (or commit) and the hash together in the script.
