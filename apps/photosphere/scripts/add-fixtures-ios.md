# add-fixtures-ios.sh

Puts photos and videos into the photo library of an iOS simulator with `xcrun simctl addmedia`, so a test has something to import.

Invoke: `bun run ios:add-fixtures -- <file...>` from the repository root, on a Mac.

- `<file...>`: the photos and videos to add. A relative path is taken from the repository root, such as `test/test.jpg` or `test/multiple-files/test.mp4`.

The simulator is picked the way [run-ios](run-ios.md) picks one; `PHOTOSPHERE_IOS_SIMULATOR` names it. There is no command that adds photos to a real iPhone's library, so with a device connected the script stops and says to add them by hand.
