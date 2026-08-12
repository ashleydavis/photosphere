//
// Asking for the photo library permission, and what to do with the answer.
//
// Automatic import on a phone reads the device photo library, which needs the user's permission.
// The decision is here as plain functions rather than in the provider, because what happens when
// permission is refused matters: the setting has to go back off, or the app sits there claiming to
// be backing photos up while it cannot see any.
//

//
// What the platform said when asked for the photo library permission.
//
export type MediaPermissionState = "granted" | "denied" | "unavailable";

//
// What the app should do about a permission answer.
//
export interface IMediaPermissionOutcome {
    // Whether automatic import may stay switched on.
    enabled: boolean;

    // What to tell the user, or undefined when there is nothing to say because it was granted.
    message: string | undefined;
}

//
// What to tell a user whose device cannot offer the photo library at all.
//
export const MEDIA_PERMISSION_UNAVAILABLE_MESSAGE =
    "This device does not offer access to a photo library, so automatic import cannot watch one.";

//
// What to tell a user who refused the photo library permission.
//
export const MEDIA_PERMISSION_DENIED_MESSAGE =
    "Photosphere needs permission to read your photos before it can import them automatically. "
    + "Grant photo access in your device settings, under Apps, Photosphere, Permissions.";

//
// Decides whether automatic import may stay on, and what to say about it.
//
// A refusal switches the setting back off rather than leaving it on and silently importing nothing.
// A user who sees the switch in the on position is entitled to believe their photos are being backed
// up, and that would not be true.
//
export function resolveMediaPermission(state: MediaPermissionState): IMediaPermissionOutcome {
    if (state === "granted") {
        return { enabled: true, message: undefined };
    }

    if (state === "unavailable") {
        return { enabled: false, message: MEDIA_PERMISSION_UNAVAILABLE_MESSAGE };
    }

    return { enabled: false, message: MEDIA_PERMISSION_DENIED_MESSAGE };
}

//
// Reads a permission answer out of whatever the plugin returned.
//
// The plugin is native code on two platforms, and a result that is not one of the states it is
// supposed to return is treated as a refusal rather than as permission. Guessing "granted" from an
// answer nobody understood is how an app ends up trying to read photos it was never allowed to see.
//
export function readPermissionState(result: IRawPermissionResult | null | undefined): MediaPermissionState {
    if (!result) {
        return "unavailable";
    }

    if (result.granted === true) {
        return "granted";
    }

    if (result.granted === false) {
        return "denied";
    }

    return "denied";
}

//
// The answer as the native plugin returns it, before it has been checked.
//
export interface IRawPermissionResult {
    // Whether the user granted the photo library permission.
    granted?: boolean;
}
