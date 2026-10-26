export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^lan-share-core$': '<rootDir>/../../packages/lan-share-core/src/index.ts',
    },
};