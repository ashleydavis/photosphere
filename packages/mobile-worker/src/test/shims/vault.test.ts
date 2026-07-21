import { getVault, getDefaultVaultType } from "../../shims/vault";
import { makeHostErrorEnvelope } from "../../shims/host-access";
import { redactingReplacer, isRedactedFieldName, REDACTED_PLACEHOLDER } from "../../lib/redact";

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

//
// The redaction boundary: derived request material (secret access key, signing key, session token,
// Authorization header) never reaches a serialised log line, even though raw secrets no longer transit
// task payloads. This is the "resolved secret never reaches the log" cover.
//
describe("serialisation-boundary redaction", () => {

    test("allowlisted field names are recognised case-insensitively", () => {
        expect(isRedactedFieldName("secretAccessKey")).toBe(true);
        expect(isRedactedFieldName("Authorization")).toBe(true);
        expect(isRedactedFieldName("sessionToken")).toBe(true);
        expect(isRedactedFieldName("signingKey")).toBe(true);
        expect(isRedactedFieldName("bucket")).toBe(false);
    });

    test("a message carrying credential material serialises with no secret in the output", () => {
        const secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
        const authorization = "AWS4-HMAC-SHA256 Credential=AKIA.../.../s3/aws4_request, Signature=deadbeef";
        const message = {
            type: "sync-batch",
            request: {
                secretAccessKey,
                sessionToken: "FQoGZXIvYXdzE...",
                authorization,
            },
            added: 3,
        };

        const serialised = JSON.stringify(message, redactingReplacer());

        expect(serialised).not.toContain(secretAccessKey);
        expect(serialised).not.toContain(authorization);
        expect(serialised).not.toContain("FQoGZXIvYXdzE");
        expect(serialised).toContain(REDACTED_PLACEHOLDER);
        // Non-sensitive fields survive.
        expect(JSON.parse(serialised).added).toBe(3);
        expect(JSON.parse(serialised).type).toBe("sync-batch");
    });
});
