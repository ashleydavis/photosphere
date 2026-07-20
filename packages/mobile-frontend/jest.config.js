export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^@capacitor/core$': '<rootDir>/src/test/capacitor-core.mock.ts',
        '^task-queue$': '<rootDir>/../../packages/task-queue/src/index.ts',
        '^lan-share-core$': '<rootDir>/../../packages/lan-share-core/src/index.ts',
        '^serialize-error$': '<rootDir>/../../packages/task-queue/__mocks__/serialize-error.js',
    },
};
