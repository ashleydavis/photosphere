export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    // These tests drive real storage: temp directories, merkle trees, and write-lock retry backoff.
    // Several legitimately run past jest's 5s default on a loaded machine, so which one tips over
    // varies per run. Raised package-wide rather than per test.
    testTimeout: 30000,
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^mime$': '<rootDir>/__mocks__/mime.js',
    },
};