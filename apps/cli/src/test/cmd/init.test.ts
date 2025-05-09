import fs from 'fs/promises';
import { initCommand } from '../../cmd/init';

// Mock fs module
jest.mock('fs/promises', () => ({
    readdir: jest.fn()
}));

// Mock dependencies
jest.mock('mime', () => ({
    getType: jest.fn().mockReturnValue('image/jpeg')
}), { virtual: true });

jest.mock('dayjs', () => () => ({
    toISOString: jest.fn().mockReturnValue('2023-01-01T00:00:00.000Z')
}), { virtual: true });

jest.mock('utils', () => ({
    uuid: jest.fn().mockReturnValue('test-uuid'),
    retry: jest.fn().mockImplementation((fn) => fn()),
    reverseGeocode: jest.fn(),
    WrappedError: class WrappedError extends Error { }
}), { virtual: true });

// Mock storage objects
const mockAssetStorage = {
    location: '/test/db',
    isEmpty: jest.fn().mockResolvedValue(true)
};

const mockMetadataStorage = {
    location: '/test/db/.db'
};

// Mock storage module
jest.mock('storage', () => ({
    createStorage: jest.fn()
        .mockImplementationOnce(() => ({ storage: mockAssetStorage }))
        .mockImplementationOnce(() => ({ storage: mockMetadataStorage }))
        .mockImplementationOnce(() => ({ storage: mockAssetStorage }))
        .mockImplementationOnce(() => ({ storage: mockMetadataStorage }))
        .mockImplementationOnce(() => ({ storage: mockAssetStorage }))
        .mockImplementationOnce(() => ({ storage: mockMetadataStorage })),
    loadEncryptionKeys: jest.fn().mockResolvedValue({ options: {} }),
    pathJoin: (base: string, path: string) => `${base}/${path}`
}));

// Mock log module
jest.mock('../../lib/log', () => ({
    log: {
        success: jest.fn(),
        verbose: jest.fn(),
        info: jest.fn(),
        warn: jest.fn(),
        error: jest.fn(),
        exception: jest.fn()
    }
}));

// Mock MediaFileDatabase
const mockCreate = jest.fn().mockResolvedValue(undefined);
jest.mock('../../lib/media-file-database', () => ({
    MediaFileDatabase: jest.fn().mockImplementation(() => ({
        create: mockCreate
    }))
}));

describe('init command', () => {
    let mockMediaFileDatabase: jest.Mock;

    beforeEach(() => {
        // Reset mocks
        jest.clearAllMocks();
        mockMediaFileDatabase = require('../../lib/media-file-database').MediaFileDatabase;
    });

    test('initCommand creates database with the correct storage objects', async () => {
        const { createStorage } = require('storage');

        await initCommand('/test/db', { meta: '/test/metadata' });

        // Check that createStorage was called
        expect(createStorage).toHaveBeenCalledTimes(2);

        // Check that MediaFileDatabase was instantiated correctly
        expect(mockMediaFileDatabase).toHaveBeenCalled();

        // Check that create was called
        expect(mockCreate).toHaveBeenCalled();
    });

    test('initCommand uses default metadata path when not specified', async () => {
        const { createStorage } = require('storage');

        await initCommand('/test/db', {});

        // Check that createStorage was called right times
        expect(createStorage).toHaveBeenCalledTimes(2);
    });

    test('initCommand logs success message', async () => {
        const { log } = require('../../lib/log');

        await initCommand('/test/db', {});

        // Check that success message was logged
        expect(log.success).toHaveBeenCalledWith('Created new media file database in "/test/db".');
    });
});