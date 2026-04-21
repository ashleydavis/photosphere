import { getVault, getDefaultVaultType } from "../lib/get-vault";
import { PlaintextVault } from "../lib/plaintext-vault";
import { MacOSKeychainVault } from "../lib/macos-keychain-vault";
import { LinuxKeychainVault } from "../lib/linux-keychain-vault";
import { WindowsKeychainVault } from "../lib/windows-keychain-vault";

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

describe("getDefaultVaultType", () => {
    const savedEnv = process.env.PHOTOSPHERE_VAULT_TYPE;

    afterEach(() => {
        if (savedEnv === undefined) {
            delete process.env.PHOTOSPHERE_VAULT_TYPE;
        }
        else {
            process.env.PHOTOSPHERE_VAULT_TYPE = savedEnv;
        }
    });

    test("returns \"keychain\" when env var is not set", () => {
        delete process.env.PHOTOSPHERE_VAULT_TYPE;
        expect(getDefaultVaultType()).toBe("keychain");
    });

    test("returns \"plaintext\" when env var is set to plaintext", () => {
        process.env.PHOTOSPHERE_VAULT_TYPE = "plaintext";
        expect(getDefaultVaultType()).toBe("plaintext");
    });

    test("returns the env var value verbatim", () => {
        process.env.PHOTOSPHERE_VAULT_TYPE = "custom-type";
        expect(getDefaultVaultType()).toBe("custom-type");
    });
});

describe("getVault(\"keychain\")", () => {
    test("returns the correct platform vault instance", () => {
        const vault = getVault("keychain");
        const expectedClass =
            process.platform === "darwin" ? MacOSKeychainVault :
            process.platform === "linux" ? LinuxKeychainVault :
            process.platform === "win32" ? WindowsKeychainVault : null;

        if (expectedClass !== null) {
            expect(vault).toBeInstanceOf(expectedClass);
        }
        else {
            // On unsupported platforms getVault("keychain") should throw, so
            // if we reach here via a known platform the assertion above handles it.
        }
    });
});
