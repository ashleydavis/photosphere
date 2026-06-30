export default {
    preset: 'ts-jest',
    testEnvironment: 'node',
    modulePathIgnorePatterns: [
        "dist",
        "build",
    ],
    moduleNameMapper: {
        '^serialize-error$': '<rootDir>/../../packages/task-queue/__mocks__/serialize-error.js',
        // Route the `http` and `net` built-ins to the mobile shims so express loads against them in
        // tests exactly as it does on device (where the bundle aliases these to the same shims).
        '^(node:)?http$': '<rootDir>/src/shims/node-http.ts',
        '^(node:)?net$': '<rootDir>/src/shims/node-net.ts',
        '^(node:)?stream/promises$': '<rootDir>/src/shims/node-stream-promises.ts',
    },
};
