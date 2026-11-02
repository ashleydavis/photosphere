# add-fixtures-android.sh

Puts photos and videos into the photo library of an Android device or emulator, in `/sdcard/DCIM/Camera` where a camera puts them, and has MediaStore index them, so a test has something to import. It fails if MediaStore does not list a file afterwards, because the app would not see it. A file with the same name as one already there replaces it.

Invoke: `bun run android:add-fixtures -- [--target <adb serial>] <file...>` from the repository root.

- `<file...>`: the photos and videos to add. A relative path is taken from the repository root, such as `test/test.jpg` or `test/multiple-files/test.mp4`.
- `--target <serial>`: the device to use (or set `PHOTOSPHERE_ANDROID_TARGET`). Without it the device is picked the way [run-android](run-android.md) picks one, so the photos land on the device `bun run android` uses.

It works on a real phone as well, where the photos stay in the phone's library afterwards.
