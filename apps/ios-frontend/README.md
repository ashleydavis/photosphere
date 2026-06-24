# ios-frontend

The iOS Photosphere mobile app: a React frontend wrapped as a native iOS app with [Capacitor](https://capacitorjs.com/) 5.

The frontend lives in `src/` and is built with [Vite](https://vitejs.dev/). The generated native iOS project lives in `ios/`, and the built web assets are copied into it during sync.

> This package uses Capacitor 5 (not 6, 7, or 8) due to the current macOS toolchain limitation. Do not upgrade the `@capacitor/*` packages past the `^5.x` line.

## Pre reqs

- [Bun](https://bun.sh).
- For iOS: a Mac with [Xcode](https://developer.apple.com/xcode/) (14.1 or higher) and [CocoaPods](https://cocoapods.org/) installed.

> The native iOS project is generated and synced on macOS. Those steps run `pod install`, which requires CocoaPods on macOS, so they do not complete on a Linux dev box; finish them on a Mac.

## Setup

Install dependencies from the repository root (this is a Bun workspace):

```bash
bun install
```

## Build and sync the web assets into the native project

```bash
cd apps/ios-frontend
bun run sync
```

This builds the frontend and copies the latest web assets into the native `ios/` project.

## iOS

You need a Mac with Xcode installed for this.

Open the project in Xcode:

```bash
cd apps/ios-frontend
bun run open
```

Once Xcode has opened:
- Hit the Run button to run the app on the iOS simulator; or
- Connect an iPhone/iPad and hit Run (you may first need to set up the device for development).

Run on iOS directly from the terminal:

```bash
cd apps/ios-frontend
bun run launch
```
