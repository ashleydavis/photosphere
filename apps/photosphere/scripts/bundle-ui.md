# bundle-ui.sh

Builds Photosphere's page with Vite (the `bundle` script of `apps/photosphere-frontend`) and puts the result in `apps/photosphere-frontend/dist`, which every shell embeds. Invoked as `bun run --filter=ziggy bundle:ui`. Takes no arguments. Runs on any platform.

The page is built into a temporary directory beside `dist` first. Other builds running at the same moment read `dist` (the Zig builds embed it), so `dist` is left untouched when the page has not changed, and a changed file is moved into place whole. A file of an earlier build that the new one no longer has is deleted by name.
