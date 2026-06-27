export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^serialize-error$': '<rootDir>/../../packages/task-queue/__mocks__/serialize-error.js',
    },
};
