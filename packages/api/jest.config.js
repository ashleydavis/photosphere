export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^mime$': '<rootDir>/__mocks__/mime.js',
        '^lan-share-core$': '<rootDir>/../../packages/lan-share-core/src/index.ts',
    },
};