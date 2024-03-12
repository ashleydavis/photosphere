## Mobile

The mobile phone version of [the Photosphere application](https://rapidfullstackdevelopment.com/example-application).

## Pre-reqs

- Node.js.
- A computer with Android Studio to build for Android.
- A MacOS computer with Xcode to build for iPhone/iPad. 
- Run the Photosphere backend (`../backend`).
- Compile the user-interface code (`../packages/user-interface`).

## Setup

Open a terminal and change directory to the Electron project:

```bash
cd photosphere-monorepo/mobile
```

Install dependencies:

```bash
ppnpm install
```

## Running in development

Run it in the browser with live reload:

```bash
pnpm start
```

## Build and run for Android

You need Android Studio installed for this.

```bash 
set BASE_URL=http://localhost:3000
pnpm run build 
pnpm run android
```

Now build and run using Android Studio.

## Build and run for iOS

You need Xcode installed for this.

```bash 
export BASE_URL=http://localhost:3000
pnpm run build
pnpm run ios 
```

Now build and run using Xcode.