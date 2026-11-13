# 67-theme

Proves the theme end to end: `--theme dark` reaches the page before it draws, the theme toggle changes the page's colours while the app
runs, the setting is written to the config file, and a restart without `--theme` reads it back. It measures each screenshot's mean
brightness, because Joy's background fills most of the window: above 0.5 in the light theme and below it in the dark one.

Run it alone with:

```
PHOTOSPHERE_SMOKE_SCENARIO=67-theme bun run test:ziggy
```
