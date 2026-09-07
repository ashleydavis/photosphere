//
// Where the mobile app's config files live in its storage sandbox.
//
// The desktop app keeps these under ~/.config/photosphere; a phone has no such place, so they sit at
// the root of the app's own storage. The paths are here, in a package with no platform of its own,
// because three different things open these files: the WebView (through worker tasks), the worker
// itself (for the background import), and the deploy and smoke-test scripts that seed a device from
// outside the app. A path spelled out separately in each of those is a path that goes wrong in one
// of them and reads an empty file rather than failing.
//

//
// Sandbox-relative path of databases.toml, the counterpart of desktop's
// ~/.config/photosphere/databases.toml. Must match DATABASES_CONFIG in
// apps/android-frontend/scripts/run-android.sh, which writes the same file.
//
export const DATABASES_CONFIG_PATH = "databases.toml";

//
// Sandbox-relative path of config.yaml, which holds every setting the app remembers: the automatic
// import settings and the database they are imported into, the two syncing settings, the database
// the background sync pushes, and the pacing of both background loops. The counterpart of desktop's
// ~/.config/photosphere/config.yaml, and the same format on both. The wiki page "Configuration-File"
// documents it for users.
//
// A file in the sandbox rather than the WebView's own store, because the background import and the
// background sync run while the app is off screen and nothing there can read the WebView. One file
// rather than one per feature, so a setting is spelled the same way whichever wrote it and resolving
// which database to sync costs one read.
//
// databases.toml is deliberately not part of this. It is what the app is looking after rather than
// how the user has asked it to behave, it is written as databases are opened rather than as settings
// are changed, and merging the two would put a settings write and a database write in contention
// over one file.
//
export const CONFIG_PATH = "config.yaml";
