# 68-system-theme

Proves that with the setting `system`, the app's theme is the operating system's theme: the page is light when the system is light and
dark when it is dark. It reads the system's theme from the platform and checks the `light` or `dark` class MUI puts on the document.
It changes nothing, so it runs on every platform.

`run.sh` runs it with every other scenario. To run it alone:

```
PHOTOSPHERE_SMOKE_SCENARIO=68-system-theme bun run test:ziggy
```
