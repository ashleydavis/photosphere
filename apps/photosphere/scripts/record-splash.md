# record-splash.sh

Starts a built app and records the screen from before it opens until after its splash screen has faded out, so the splash can be
checked frame by frame. The `Splash videos` workflow (`.github/workflows/splash-videos.yml`) runs it on every platform and uploads
the videos.

Invoke: `bash apps/photosphere/scripts/record-splash.sh --platform <platform> --app <path> --output <video> [--seconds <n>] [--package <id>]`

- `--platform <linux|windows|macos|ios|android>`: the platform the app was built for.
- `--app <path>`: the built app: the executable on Linux and Windows, the `.app` bundle on macOS, the simulator `.app` bundle on
  iOS, the `.apk` on Android.
- `--output <video>`: the video file to write. Its folder is made when it does not exist.
- `--seconds <n>`: how long to record after the app starts. Default 12, enough for the splash's minimum display time and its fade.
- `--package <id>`: the app's package name. Needed on Android, where it is how the app is started.

What it needs and does on each platform:

- **Linux**: `Xvfb` and `ffmpeg`. Records a display of its own, 1280x1000, with `ffmpeg`'s x11grab, and starts the app on it with
  `ZIGGY_THEME=dark` unless `ZIGGY_THEME` is already set.
- **Windows**: `ffmpeg`. Records the whole desktop with `ffmpeg`'s gdigrab.
- **macOS**: records the main display with `screencapture`, which needs the screen recording permission.
- **iOS**: `xcrun` and `jq`. Installs the app on the simulator `ZIGGY_IOS_SIMULATOR` names, else one already booted, else the first
  available iPhone, and records it with `simctl io recordVideo`.
- **Android**: `adb`. Installs the app on the device `ANDROID_SERIAL` names (else adb's only device) and records it with
  `screenrecord`.

It fails when no video was recorded.
