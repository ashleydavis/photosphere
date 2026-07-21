//
// A [redacted] allowlist applied at the worker's serialisation boundary, so secret-derived request
// material never reaches a log line.
//
// After step 14b the worker fetches raw secret values from the keychain itself (via secureStoreGet),
// so raw secrets no longer transit task payloads. What can still be derived inside the worker is
// SigV4 material: the secret access key is combined into a signing key, and a signature goes into the
// `Authorization` header. Because task messages and results are JSON-serialised as they cross the
// native bridge (where they can be written to `app.log`), this redacts an allowlist of field names by
// name at that boundary, rather than grepping at the sink. The allowlist is intentionally small: the
// fields that carry credential material and nothing else.
//

//
// The value substituted for an allowlisted (sensitive) field.
//
export const REDACTED_PLACEHOLDER = "[redacted]";

//
// The lowercased field names redacted at the serialisation boundary: the secret access key, any
// derived signing key, the session token, and the Authorization header.
//
const REDACTED_FIELD_NAMES: ReadonlySet<string> = new Set([
    "secretaccesskey",
    "signingkey",
    "sessiontoken",
    "authorization",
    "x-amz-security-token",
]);

//
// Returns true when a field name is on the redaction allowlist (case-insensitive).
//
export function isRedactedFieldName(name: string): boolean {
    return REDACTED_FIELD_NAMES.has(name.toLowerCase());
}

//
// A JSON.stringify replacer signature.
//
export type JsonReplacer = (this: unknown, key: string, value: unknown) => unknown;

//
// Wraps a base JSON replacer so any allowlisted field name serialises as `[redacted]`. Non-sensitive
// fields defer to the base replacer (used to preserve the binary/date bridge tagging). Composes at the
// serialisation boundary, so the redaction cannot be forgotten at an individual log call.
//
export function redactingReplacer(baseReplacer?: JsonReplacer): JsonReplacer {
    return function redact(this: unknown, key: string, value: unknown): unknown {
        if (key.length > 0 && isRedactedFieldName(key)) {
            return REDACTED_PLACEHOLDER;
        }
        return baseReplacer ? baseReplacer.call(this, key, value) : value;
    };
}
