export default {
    preset: 'ts-jest',
    modulePathIgnorePatterns: [
        "build",
    ],
    // RSA key generation in loadEncryptionKeys can exceed Jest's 5s default when the test runner
    // is under heavy parallel load (e.g. running alongside the merkle-tree and bdb suites).
    testTimeout: 30000,
};
