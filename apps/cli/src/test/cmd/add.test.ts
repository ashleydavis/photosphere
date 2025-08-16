import { IStorage } from 'storage';
import { addCommand } from '../../cmd/add';

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

// Create mock function references
const mockLoad = jest.fn().mockResolvedValue(undefined);
const mockAddPaths = jest.fn().mockResolvedValue(undefined);
const mockClose = jest.fn().mockResolvedValue(undefined);
const mockGetAddSummary = jest.fn().mockReturnValue({
    numFilesAdded: 5,
    numFilesAlreadyAdded: 2,
    numFilesIgnored: 1,
    numFilesFailed: 0,
    totalSize: 1024,
    averageSize: 256
});

// Create mock storage objects before using them in the mocks
const mockAssetStorage: jest.Mocked<IStorage> = {
    location: '/test/db',
    isReadonly: false,
    isEmpty: jest.fn(),
    listFiles: jest.fn(),
    listDirs: jest.fn(),
    fileExists: jest.fn(),
    dirExists: jest.fn(),
    info: jest.fn(),
    read: jest.fn(),
    write: jest.fn(),
    readStream: jest.fn(),
    writeStream: jest.fn(),
    deleteFile: jest.fn(),
    deleteDir: jest.fn(),
    copyTo: jest.fn(),
};

const mockMetadataStorage: jest.Mocked<IStorage> = {
    location: '/test/db/.db',
    isReadonly: false,
    isEmpty: jest.fn(),
    listFiles: jest.fn(),
    listDirs: jest.fn(),
    fileExists: jest.fn(),
    dirExists: jest.fn(),
    info: jest.fn(),
    read: jest.fn(),
    write: jest.fn(),
    readStream: jest.fn(),
    writeStream: jest.fn(),
    deleteFile: jest.fn(),
    deleteDir: jest.fn(),
    copyTo: jest.fn(),
};

// Mock storage directly
jest.mock('storage', () => ({
    createStorage: jest.fn().mockImplementation((location, options) => {
        if (location.includes('.db') || location === '/test/metadata') {
            return { storage: mockMetadataStorage };
        }
        return { storage: mockAssetStorage };
    }),
    loadEncryptionKeys: jest.fn().mockResolvedValue({ options: {} }),
    pathJoin: (base: string, path: string) => `${base}/${path}`
}));

// Mock log module
jest.mock('utils', () => ({
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
jest.mock('api', () => ({
    MediaFileDatabase: jest.fn().mockImplementation(() => ({
        load: mockLoad,
        addPaths: mockAddPaths,
        close: mockClose,
        getAddSummary: mockGetAddSummary
    }))
}));


describe('add command', () => {
    beforeEach(() => {
        // Reset mocks
        jest.clearAllMocks();
    });

    test('addCommand creates database with the correct storage objects', async () => {
        const { createStorage } = require('storage');
        const { MediaFileDatabase } = require('api');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db', meta: '/test/metadata' });

        // Check that createStorage was called
        expect(createStorage).toHaveBeenCalledTimes(2);
        expect(createStorage).toHaveBeenCalledWith('/test/db', {});
        expect(createStorage).toHaveBeenCalledWith('/test/metadata');

        // Check that MediaFileDatabase was instantiated correctly
        expect(MediaFileDatabase).toHaveBeenCalled();
    });

    test('addCommand uses default metadata path when not specified', async () => {
        const { createStorage } = require('storage');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that createStorage was called with the default metadata path
        expect(createStorage).toHaveBeenCalledTimes(2);
        expect(createStorage).toHaveBeenCalledWith('/test/db', {});
        expect(createStorage).toHaveBeenCalledWith('/test/db/.db');
    });

    test('addCommand calls database.load()', async () => {
        const { MediaFileDatabase } = require('api');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that load was called
        expect(MediaFileDatabase.mock.results[0].value.load).toHaveBeenCalled();
    });

    test('addCommand calls addPaths with the provided file paths', async () => {
        const { MediaFileDatabase } = require('api');
        const filePaths = ['/path/to/file1.jpg', '/path/to/file2.jpg', '/path/to/dir'];

        await addCommand(filePaths, { db: '/test/db' });

        // Check that addPaths was called with the file paths
        expect(MediaFileDatabase.mock.results[0].value.addPaths).toHaveBeenCalledWith(filePaths);
    });

    test('addCommand closes the database when done', async () => {
        const { MediaFileDatabase } = require('api');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that the database was closed
        expect(MediaFileDatabase.mock.results[0].value.close).toHaveBeenCalled();
    });

    test('addCommand gets and displays the add summary', async () => {
        const { MediaFileDatabase } = require('api');
        const { log } = require('utils');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that getAddSummary was called
        expect(MediaFileDatabase.mock.results[0].value.getAddSummary).toHaveBeenCalled();

        // Check that the summary details were logged
        expect(log.success).toHaveBeenCalledWith('Added files to the media database.');
        expect(log.info).toHaveBeenCalledWith('Details: ');
        expect(log.info).toHaveBeenCalledWith('  - 5 files added.');
        expect(log.info).toHaveBeenCalledWith('  - 1 files ignored.');
        expect(log.info).toHaveBeenCalledWith('  - 0 files failed to be added.');
        expect(log.info).toHaveBeenCalledWith('  - 2 files already in the database.');
        expect(log.info).toHaveBeenCalledWith('  - 1024 bytes added to the database.');
        expect(log.info).toHaveBeenCalledWith('  - 256 bytes average size.');
    });
});