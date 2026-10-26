# Stories Browser

A minimal, Storybook-like browser that mounts every page, modal, dialog, and component shipped from `user-interface` in isolation, with mock data and mock interactions wired in.

## Why it exists

The stories browser lets developers view, exercise, and visually compare each UI surface without launching the full application or seeding a real database. The story player (`bun run stories:ziggy`, see below) cycles the live app through every story on any platform, dwelling at each one, capturing a screenshot, and failing on any story that crashes while rendering.

Playing the stories is the only thing that catches a broken story. There is no unit test that mounts them: the project does not unit-test React components, so a story that throws (say, a dialog whose context provider is missing from the mocks) will not fail `bun run test`. Play the stories after changing a page, component, or the mock provider stack.

Because the same stories render in the Photosphere App on every platform, running them on a phone-sized screen is the quickest way to find pages that do not fit on mobile.

## Entry points

The browser is deliberately not exposed to end users. The ways in:

- **Photosphere App, any platform:** turn on developer mode by tapping the version label on the About page four times in quick succession, then open **Developer** from the sidebar and tap **Stories**. There is no other in-app affordance.
- **Any platform, automated:** the story player drives the live app through the whole registry from the command line. See [Running the stories](#running-the-stories).

A **Back to app** link in the sidebar navigates back to `/`.

## Play on automatic

The sidebar has a **▶ Play on automatic** button that walks every story in order, dwelling briefly on each, and reports how many passed or failed at the end. By default it shows each story in **light and then dark**; when `PHOTOSPHERE_THEME` forces a single theme (the screenshot passes) it walks only that theme. During playback the only control is **Cancel**; the completion screen has a **Back to browser** button. Under the hood this just sets the `?cycle=1` query param the cycle reads, so it works identically on every platform.

## Theming

The browser has a **light/dark toggle button** (top-right, left of the dev-tools button) to switch theme while viewing stories; it uses MUI Joy's `setMode` and writes localStorage only, never the config file.

The initial color mode is controlled by the `PHOTOSPHERE_THEME` build-time env var (`light`, `dark`, or `system`), the same mechanism used app-wide (see `docs/theme-override.md`). When set, it is applied on startup over the saved theme and is never written to the config file; when unset the stories page uses the system theme. There is no theme query param.

## Running the stories

`scripts/story-player.sh` is the story player. It builds the app, launches it in test mode, navigates it to `#/stories?cycle=1`, walks every story in light and then dark, captures a screenshot of each, and fails the run if any story crashes while rendering:

```bash
bun run stories:ziggy      # Photosphere App on the host operating system
bun run stories:ziggy:and  # Photosphere App on an Android emulator from the pool, or an attached device
bun run stories:ziggy:ios  # Photosphere App on the iOS simulator
```

On Android the player plays on an emulator from the pool, or an attached device, and builds and installs the APK. On iOS it needs the simulator and Xcode.

Options are passed after `--`, e.g. `bun run stories:ziggy:and -- --open`:

| Option | Meaning |
|---|---|
| `--platform <ziggy\|ziggy-android\|ziggy-ios>` | Which shell to run on. The `stories:ziggy*` scripts set this for you. |
| `--duration <ms>` | Dwell per story. This is only a fallback and does not pace a normal run: the player advances as soon as it has captured the screenshot. It must comfortably outlast a single capture, because if it expires mid-capture the app advances underneath the screenshot and the wrong image is saved under that story's name. Defaults to 5000ms on the host operating system and 30000ms on mobile, where `adb`/`simctl` capture can take seconds. |
| `--screenshots <dir>` | Where the PNGs go. Defaults to `stories-screenshots/<platform>/`. |
| `--no-screenshots` | Play the stories without capturing anything (a pure crash check). |
| `--open` | Open the generated index in a browser when the run finishes. |
| `--headless` | The Photosphere App on Linux only: hide the window and run under `xvfb` (for CI). |

The app is **visible by default** so you can watch the stories cycle: the Photosphere App window opens, and the Android emulator / iOS simulator is on screen anyway. Pass `--headless` when you do not want the window on Linux (the smoke tests, by contrast, are headless by default).

Screenshots land in `<dir>/<theme>/<category>/<story-id>.png`, and an `index.html` is generated at the root of the screenshots directory showing each story's light and dark shots **side by side**, with a search box that filters by story id. Open it to review every story in both themes at once. Output directories are gitignored.

Because Android and iOS run at phone resolution, `bun run stories:ziggy:and` is the fastest way to catch a page that overflows a small screen (content pushed off-screen, buttons out of reach, text clipped).

### How it works on each platform

The platforms differ only in how the app is built, launched, and screenshotted. Every one is driven through the Photosphere App smoke tests' harness (`apps/photosphere-smoke-tests/lib/common.sh`), which exposes the same command surface (ready, navigate, screenshot, cycle-advance, quit) over Ziggy's test control connection, so the player drives them identically:

- **Host operating system:** the app writes each screenshot itself.
- **Android / iOS:** the app cannot write to a host path, so the harness captures the screen host-side with `adb exec-out screencap` (Android) or `xcrun simctl io screenshot` (iOS). The player builds and installs the app first.

The cycle itself lives in `stories-page.tsx` (`StoriesCycle`): it renders each story, emits `STORIES CYCLE READY: <theme>|<category>|<id>` once the story has settled, and advances when the player posts `/cycle-advance` (or when the dwell timer expires). It ends with `STORIES CYCLE COMPLETE: N passed, M failed`, which is what the player reports.

## Outside the provider stack

The `/stories` route is mounted at the top level of each consuming frontend, sibling to (not child of) the normal context provider stack. Each story's `render` function is responsible for wrapping its content in whatever providers it needs. The shared `MockProviders` wrapper in `./mocks` is the default; stories that want to vary mocks pass overrides to `MockProviders` or use the underlying real provider with a custom value.

Without this isolation, stories would inherit the live `AssetDatabaseProvider` and other production contexts and would render against real (or partially-mocked) application state, which defeats the purpose of the browser.

## Adding a new story

1. Create `<name>.stories.tsx` under the appropriate subdirectory (`pages/`, `modals/`, `dialogs/`, or `components/`).
2. Export `const stories: IStory[]`. Each entry needs `id`, `name`, `category`, and `render`.
3. Add one import + one spread to `src/stories/index.ts`.

Story `id` values must be globally unique. The convention is `<component-file-name>/<variant>`, lowercased and kebab-cased.

## Comprehensive coverage

Every page, modal, dialog, and component shipped from `user-interface` must have at least one story. Nothing enforces this automatically today, so add the story when you add the component, and play the stories to confirm it renders.
