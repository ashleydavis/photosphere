# cut-to-splash.sh

Cuts a splash recording to start at the first frame in which the app's splash fills the screen, so the video does not show what was
on the screen before the app opened: the launcher on Android, the home screen on iOS, and either around the app's window as it opens.
[record-splash.sh](record-splash.md) sources it for its Android recordings. The iOS recording is not cut, because macOS's ffmpeg
crashed cutting it; run this script on Linux to cut it.

Invoke: `bash apps/photosphere/scripts/cut-to-splash.sh <video> <output> <top rows>`

- `<video>`: the recording to cut.
- `<output>`: the video to write.
- `<top rows>`: two rows near the top of the screen that must have the splash colour, as ffmpeg's crop filter takes them:
  `iw/2:2:iw/4:0` (the top edge) on Android, and `iw/2:2:iw/4:ih/10` (a tenth of the way down, below the status bar and the camera
  cut-out) on iOS.

The first splash frame is the first in which five areas all have the splash colour from `icons/assets.json`, to within 6 in each
channel: bands across the screen near its top and its bottom, the two pixel columns at its left and right edges, and the top rows.
Every frame keeps its own time. It needs `ffmpeg` and `jq`, and fails, printing what the recording had, when no frame has the splash.
