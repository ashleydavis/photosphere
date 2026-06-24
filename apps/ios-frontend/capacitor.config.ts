import { CapacitorConfig } from '@capacitor/cli';

// Capacitor configuration for the iOS Photosphere frontend.
const config: CapacitorConfig = {
    // Reverse-DNS application id (placeholder; reconcile with the desktop bundle id before any store build).
    appId: 'au.com.codecapers.photosphere',

    // Human-readable application name shown on the device.
    appName: 'Photosphere',

    // Directory containing the built web assets that Capacitor copies into the native project.
    webDir: 'dist',

    // No Capacitor plugins configured yet.
    plugins: {},
};

export default config;
