export default {
    preset: 'ts-jest',
    testEnvironment: 'jsdom',
    setupFilesAfterEnv: ["<rootDir>/src/test/setup.ts"],
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
};
