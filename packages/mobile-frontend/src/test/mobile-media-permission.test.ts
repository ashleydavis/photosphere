import {
    MEDIA_PERMISSION_DENIED_MESSAGE,
    MEDIA_PERMISSION_UNAVAILABLE_MESSAGE,
    readPermissionState,
    resolveMediaPermission,
} from "../lib/mobile-media-permission";

describe("resolveMediaPermission", () => {

    test("a granted permission leaves automatic import on, with nothing to say", () => {
        const outcome = resolveMediaPermission("granted");

        expect(outcome.enabled).toBe(true);
        expect(outcome.message).toBeUndefined();
    });

    test("a refused permission switches automatic import back off and explains why", () => {
        const outcome = resolveMediaPermission("denied");

        expect(outcome.enabled).toBe(false);
        expect(outcome.message).toBe(MEDIA_PERMISSION_DENIED_MESSAGE);
    });

    test("the explanation says where to grant it", () => {
        expect(MEDIA_PERMISSION_DENIED_MESSAGE).toMatch(/settings/i);
        expect(MEDIA_PERMISSION_DENIED_MESSAGE).toMatch(/permission/i);
    });

    test("a device with no photo library switches automatic import off and says so", () => {
        const outcome = resolveMediaPermission("unavailable");

        expect(outcome.enabled).toBe(false);
        expect(outcome.message).toBe(MEDIA_PERMISSION_UNAVAILABLE_MESSAGE);
    });
});

describe("readPermissionState", () => {

    test("granted is granted", () => {
        expect(readPermissionState({ granted: true })).toBe("granted");
    });

    test("refused is refused", () => {
        expect(readPermissionState({ granted: false })).toBe("denied");
    });

    test("no answer at all means the platform cannot offer it", () => {
        expect(readPermissionState(undefined)).toBe("unavailable");
        expect(readPermissionState(null)).toBe("unavailable");
    });

    test("an answer nobody understands is treated as a refusal, not as permission", () => {
        expect(readPermissionState({} as any)).toBe("denied");
        expect(readPermissionState({ granted: "yes" } as any)).toBe("denied");
        expect(readPermissionState({ granted: 1 } as any)).toBe("denied");
    });
});
