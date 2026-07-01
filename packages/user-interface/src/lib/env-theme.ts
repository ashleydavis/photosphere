//
// How the theme override works
// ----------------------------
// Set the PHOTOSPHERE_THEME env var (light | dark | system) when building or
// running any frontend to force the startup theme. Each frontend's Vite config
// bakes the value in as the `__PHOTOSPHERE_THEME__` global; on startup the app
// reads it here (resolveInitialTheme) and applies it with MUI Joy's setMode.
// The override wins over the saved theme but is NEVER written to the config
// file, so your saved theme is untouched and you can still change theme in the
// app. With no env var set, the app starts from the saved theme (system by
// default). Usage: docs/theme-override.md.
//

//
// The three color modes MUI Joy supports. "system" follows the OS preference.
//
export type ThemeMode = "light" | "dark" | "system";

//
// Build-time theme override baked into the frontend from the PHOTOSPHERE_THEME
// environment variable via each frontend's Vite `define`. It is an empty string
// when the env var was not set at build time, and is undefined in non-Vite
// contexts such as Jest (where the define is never applied). The `typeof` guard
// below keeps this safe everywhere.
//
declare const __PHOTOSPHERE_THEME__: string;

//
// Returns the raw build-time theme override, or an empty string when it was not
// set (or when running outside a Vite build, e.g. under Jest).
//
export function themeOverrideFromEnv(): string {
    return typeof __PHOTOSPHERE_THEME__ === "string" ? __PHOTOSPHERE_THEME__ : "";
}

//
// Resolves the initial color mode to apply on startup. When the PHOTOSPHERE_THEME
// env override is a valid mode it wins (used to launch a smoke test in a specific
// theme); otherwise the saved/default mode is used. The override is applied on
// startup only via setMode and is never written to the config file, so it does
// not change the user's saved theme and can still be changed in the app.
//
export function resolveInitialTheme(envOverride: string, savedTheme: ThemeMode): ThemeMode {
    if (envOverride === "light" || envOverride === "dark" || envOverride === "system") {
        return envOverride;
    }
    return savedTheme;
}
