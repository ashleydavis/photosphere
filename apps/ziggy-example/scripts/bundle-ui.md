# bundle-ui.sh

Builds the example's page with Vite and puts the result in `apps/ziggy-example/dist`, which every platform embeds. Run through the `bundle:ui` script of `apps/ziggy-example`. No arguments.

The page is built into a directory of its own first. Builds of the app read `dist` while they run, and several runs can be at it at once, so `dist` is not emptied and rewritten in place: when the built page is the same as `dist` nothing in `dist` is touched, and otherwise each changed file is moved into place whole and a file the new build no longer has is deleted.
