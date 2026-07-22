import { getVault, getDefaultVaultType } from "../../shims/vault";
import { makeHostErrorEnvelope } from "../../shims/host-access";

//
// Installs a mock native host whose secureStoreGet returns the given map value: a string (configured),
// null (unconfigured), or a host error envelope string (unavailable, which callHost decodes to a throw).
//
function installSecureStoreHost(store: Record<string, string | null>, unavailable?: boolean): void {
    (globalThis as any).host = {
        platform: "android",
        secureStoreGet: (key: string): string | null => {
            if (unavailable) {
                return makeHostErrorEnvelope("EHOST", "keychain unavailable");
            }
            return key in store ? store[key] : null;
        },
    };
}

describe("mobile worker vault shim", () => {

    afterEach(() => {
        delete (globalThis as any).host;
    });

    test("getDefaultVaultType identifies the keychain vault", () => {
        expect(getDefaultVaultType()).toBe("keychain");
    });

    test("resolves a configured secret through secureStoreGet", async () => {
        // The app stores each secret value under the prefixed key (photosphere.secret.<name>), so the
        // vault reads it back by that same key when given the bare secret name.
        installSecureStoreHost({ "photosphere.secret.my-encryption-key": "PEM-VALUE" });
        const secret = await getVault(getDefaultVaultType()).get("my-encryption-key");
        expect(secret).toEqual({ value: "PEM-VALUE" });
    });

    test("a missing secret (unconfigured) resolves to undefined", async () => {
        installSecureStoreHost({});
        const secret = await getVault(getDefaultVaultType()).get("absent-key");
        expect(secret).toBeUndefined();
    });

    test("an unavailable keychain throws, distinguishably from unconfigured", async () => {
        installSecureStoreHost({}, true);
        await expect(getVault(getDefaultVaultType()).get("any-key")).rejects.toThrow(/keychain unavailable/);
    });
});
