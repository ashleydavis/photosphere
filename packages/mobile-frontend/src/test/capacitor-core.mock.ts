//
// Jest mock for @capacitor/core. The real module needs a Capacitor runtime; in unit tests
// we only need registerPlugin to return a stand-in object and to record how it was called.
// Mapped in via jest.config.js moduleNameMapper so every test sees the same stub.
//

//
// Records each registerPlugin call and returns a named stand-in plugin object.
//
export const registerPlugin = jest.fn((pluginName: string) => {
    return { __pluginName: pluginName };
});

//
// Runtime placeholder for the PluginListenerHandle type (type-only in real code).
//
export interface PluginListenerHandle {
    // Removes the listener.
    remove(): Promise<void>;
}
