# bundle-ui.sh

Builds Photosphere's page with Vite (the `bundle` script of `apps/photosphere-frontend`) and puts the result in `apps/photosphere-frontend/dist`, which every native app embeds. Invoked as `bun run --filter=ziggy bundle:ui`. Runs on any platform.

- `--minify`: minifies the page. The release packages pass it, because the page is embedded in the app and its size is the app's size. Every other build leaves the page unminified, so the stack traces in the log name the real functions.

The page is built into a temporary directory beside `dist` first. Other builds running at the same moment read `dist` (the Zig builds embed it), so `dist` is left untouched when the page has not changed, and a changed file is moved into place whole. A file of an earlier build that the new one no longer has is deleted by name.
