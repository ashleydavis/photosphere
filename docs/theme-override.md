# Forcing a theme with --theme

`--theme light|dark|system` on the app's command line starts it in that theme for one run. On Android the Intent extra `ziggy.theme` does the same, because an Android app is started with an Intent, not a command line.

- The value is **never written to the config file**, so a forced run leaves the user's saved setting alone.
- A theme chosen in the app while it runs is saved, as normal.
- With no `--theme`, the app starts from the config file's `theme`, or `system` when the file has none.
- A value that is not `light`, `dark` or `system` fails the start with `UnknownTheme`.

The theme is Ziggy's: the native app sets the web view's colour scheme before it loads the page, so a page follows it with `prefers-color-scheme`, and `getConfig("theme")` and `config-changed` report the setting. See Ziggy's [Theme](https://github.com/ashleydavis/ziggy/blob/main/docs/user-guide/theme.md) guide.

## Running the app in a theme

Desktop (use `linux`, `windows` or `macos` for the operating system you are on):

```
bun run linux -- --theme dark
```

Mobile: start the app with the `ziggy.theme` extra, or set `PHOTOSPHERE_SMOKE_THEME` for a smoke test.

## Running a smoke test in a theme

```
PHOTOSPHERE_SMOKE_THEME=dark bun run test:ziggy
PHOTOSPHERE_SMOKE_THEME=light bun run test:ziggy:and
```

The story player (`bun run stories:ziggy`) switches theme at runtime and captures every story in both light and dark, so it needs no theme override; see `packages/user-interface/src/stories/README.md`.
