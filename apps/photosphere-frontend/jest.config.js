export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^task-queue$': '<rootDir>/../../packages/task-queue/src/index.ts',
        '^serialize-error$': '<rootDir>/../../packages/task-queue/__mocks__/serialize-error.js',
    },
};
