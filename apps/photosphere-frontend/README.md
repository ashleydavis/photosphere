# Photosphere Ziggy frontend

The platform layer that runs Photosphere's shared React user interface (`packages/user-interface`) on Ziggy, on desktop and on phones. It is the only place that knows the app is running on Ziggy: everything it does goes through `window.ziggy`.

The shared interface is unchanged. This package supplies what it asks of its platform:

- `src/lib/app-messages.ts`: Photosphere's own messages and events over `window.ziggy`. It sends a message with its name and its payload (`invoke(name, data)` or `send(name, data)`), and hands each event, whose data is `{type, data}`, to the listeners for its type.
- `src/lib/ziggy-queue-backend.ts`: the task queue backend. It queues tasks with `window.ziggy.addTask`, cancels with the `main-command` message `cancel-tasks` and turns Ziggy's `task-message` and `task-completed` events (`onTaskMessage`, `onTaskCompleted`) back into callbacks.
- `src/lib/platform-provider-ziggy.tsx`: the platform context. The core answers the same messages on every platform, so most members are the same on desktop and phone. The few that differ check the `platformKind` and `os` that `window.ziggy.getPlatform()` reports.
- `src/lib/menu-actions.ts`: what the page does for the menu items the core sends it as the app event `{type: "menu", item}` (`navigate:<route>`, `about`, `theme:<name>`, `open-log-directory`, `help`, `close-database` and every other item, which is passed on as a platform event). The platform provider listens for that event with `window.ziggy.onEvent`.
- `src/lib/mobile-export.ts`: how a phone saves downloads, by writing them into the app's private storage and handing them out through the share sheet.
- `src/lib/renderer-log.ts`: the page's log, which goes to the core in `renderer-log` messages.
- `src/lib/ziggy-test-transport.ts`: in test mode, carries the shared test driver's commands over Ziggy's `test-command` events (`window.ziggy.onTestCommand`) and answers with `window.ziggy.sendTestResult`.
- `src/lib/mcp-tool-handler.tsx` and `src/lib/preview-banner.tsx`: parts of the desktop app only. They are rendered only when the platform is a desktop.

`src/main.tsx` asks the core for the platform, installs the page's error forwarding (and, in test mode, console forwarding and the test driver), and renders `src/app.tsx`. The page reads `restApiUrl`, `theme` and `testMode` from its query string, which the core supplies.

## Commands

Run from this directory, or from the repository root with `--filter`.

- `bun run bundle`: builds the page into `dist`, which the app builds embed. There are no source maps.
- `bun run compile`: type checks.
- `bun run test`: runs the unit tests of the functions in `src/lib`. React components, contexts and hooks are not unit tested.

The Content-Security-Policy in `index.html` allows the two origins the page is served from (`ziggy-app://app` on Linux, MacOS and iOS and `https://ziggy-app.invalid` on Windows and Android) and the loopback address the asset server listens on.
