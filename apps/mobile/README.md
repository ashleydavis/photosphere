## Photosphere mobile

The mobile phone version of [the Photosphere application](https://rapidfullstackdevelopment.com/example-application).

## Pre-reqs

- Bun.
- A computer with Android Studio to build for Android.
- A MacOS computer with Xcode to build for iPhone/iPad. 
- Run [the backend](../backend/README.md).

## Setup

First, follow the instructions in [the main readme](../README.md).

Then open a terminal and change directory to the mobile project:

```bash
cd mobile
```

## Running in development

Run it in the browser with live reload:

```bash
bun start
```

## Build and run for Android

You need Android Studio installed for this.

```bash 
set BASE_URL=http://localhost:3000
set GOOGLE_API_KEY=""
bun run build 
bun run android
```

Now build and run using Android Studio.

## Build and run for iOS

You need Xcode installed for this.

```bash 
export BASE_URL=http://localhost:3000
export GOOGLE_API_KEY=""
bun run build
bun run ios 
```

Now build and run using Xcode.

Be sure to enable Developer mode on your iPhone and allow "Untrusted Developer" under Settings > General > VPN & Device Management.

## Debugging the frontend

Make sure the mobile device is on the same network as your development computer.

After connecting, open the Console and run `location.reload()` to reload the web page.

### Connecting on Android

On your development computer, open Chrome and navigate to chrome://inspect 

### Connecting on iOS

On your development computer, open Safari and find your device under the Develop menu.

On iOS go into Settings > Safari > Advanced and enable Web Inspector. You might need to restart the device.
