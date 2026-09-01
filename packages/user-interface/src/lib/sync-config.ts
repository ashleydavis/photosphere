//
// The config keys the two syncing settings are stored under.
//
// They are named here, in the shared package, because the settings card writes the same two keys on
// every platform and each platform decides where they are kept: the desktop puts them in its own
// settings file, and mobile routes them to sync.toml in the app's storage sandbox, where the
// background sync loop can read them while there is no WebView.
//

//
// Config key holding whether automatic syncing is switched on.
//
export const SYNC_ENABLED_CONFIG_KEY = "syncEnabled";

//
// Config key holding whether automatic syncing is restricted to Wi-Fi.
//
export const SYNC_ONLY_ON_WIFI_CONFIG_KEY = "syncOnlyOnWifi";
