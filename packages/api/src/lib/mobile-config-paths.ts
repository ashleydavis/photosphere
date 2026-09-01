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
// Sandbox-relative path of auto-import.toml, which holds the automatic import settings and the
// database they are imported into.
//
// These used to be in the WebView's localStorage, where nothing that runs while the app is off
// screen could read them, which is why the background import could not know whether it was switched
// on.
//
export const AUTO_IMPORT_CONFIG_PATH = "auto-import.toml";

//
// Sandbox-relative path of sync.toml, which holds the two automatic syncing settings and the pacing
// of the background sync loop.
//
// A separate file from auto-import.toml because these are separate features: switching automatic
// import off must not switch syncing off, and a user who opens one of these files to change a
// setting should not find the other feature's settings in it. The database that is synced is not
// recorded here either, for the same reason: it is the one automatic import writes to, and that is
// recorded in auto-import.toml alone.
//
export const SYNC_CONFIG_PATH = "sync.toml";
