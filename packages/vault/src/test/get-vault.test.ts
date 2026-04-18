import { getVault } from "../lib/get-vault";
import { PlaintextVault } from "../lib/plaintext-vault";

// Reset the singleton cache between tests by re-importing a fresh module state.
// Jest module isolation means each test file gets its own module registry, so
// the singleton map starts empty for this suite.

describe("getVault", () => {
    test("returns a PlaintextVault for type \"plaintext\"", () => {
        const vault = getVault("plaintext");
        expect(vault).toBeInstanceOf(PlaintextVault);
    });

    test("returns the same instance on repeated calls for the same type", () => {
        const first = getVault("plaintext");
        const second = getVault("plaintext");
        expect(first).toBe(second);
    });

    test("throws for an unknown vault type", () => {
        expect(() => getVault("bitwarden")).toThrow(/Unknown vault type/);
    });

    test("error message includes the unrecognised type name", () => {
        expect(() => getVault("1password")).toThrow(/"1password"/);
    });
});
