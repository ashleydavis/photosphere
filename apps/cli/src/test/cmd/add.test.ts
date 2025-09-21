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
const mockAddPaths = jest.fn().mockImplementation(async (paths, progressCallback) => {
    // Call progress callback to simulate progress
    if (progressCallback) {
        progressCallback({ message: 'Processing files...' });
    }
    return undefined;
});
const mockClose = jest.fn().mockResolvedValue(undefined);
const mockGetAddSummary = jest.fn().mockReturnValue({
    filesAdded: 5,
    filesAlreadyAdded: 2,
    filesIgnored: 1,
    filesFailed: 0,
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
    checkWriteLock: jest.fn(),
    acquireWriteLock: jest.fn(),
    releaseWriteLock: jest.fn(),
};

const mockMetadataStorage: jest.Mocked<IStorage> = {
    location: '/test/db/.db',
    isReadonly: false,
    isEmpty: jest.fn(),
    listFiles: jest.fn(),
    listDirs: jest.fn(),
    fileExists: jest.fn().mockResolvedValue(true), // Make tree.dat exist
    dirExists: jest.fn(),
    info: jest.fn(),
    read: jest.fn(),
    write: jest.fn(),
    readStream: jest.fn(),
    writeStream: jest.fn(),
    deleteFile: jest.fn(),
    deleteDir: jest.fn(),
    copyTo: jest.fn(),
    checkWriteLock: jest.fn(),
    acquireWriteLock: jest.fn(),
    releaseWriteLock: jest.fn(),
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
const mockGetAssetDatabase = jest.fn().mockReturnValue({
    getMerkleTree: jest.fn().mockReturnValue({
        getSchema: jest.fn().mockReturnValue({ version: 2 })
    })
});

jest.mock('api', () => ({
    MediaFileDatabase: jest.fn().mockImplementation(() => ({
        load: mockLoad,
        addPaths: mockAddPaths,
        close: mockClose,
        getAddSummary: mockGetAddSummary,
        getAssetDatabase: mockGetAssetDatabase
    })),
    checkVersionCompatibility: jest.fn().mockReturnValue({ isCompatible: true })
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
        expect(createStorage).toHaveBeenCalledTimes(3);
        expect(createStorage).toHaveBeenCalledWith('/test/db', {}, {readonly: false});
        expect(createStorage).toHaveBeenCalledWith('/test/metadata', {}, {readonly: false});

        // Check that MediaFileDatabase was instantiated correctly
        expect(MediaFileDatabase).toHaveBeenCalled();
    });

    test('addCommand uses default metadata path when not specified', async () => {
        const { createStorage } = require('storage');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that createStorage was called with the default metadata path
        expect(createStorage).toHaveBeenCalledTimes(3);
        expect(createStorage).toHaveBeenCalledWith('/test/db', {}, {readonly: false});
        expect(createStorage).toHaveBeenCalledWith('/test/db/.db', {}, {readonly: false});
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

        // Check that addPaths was called with the file paths (and a progress callback)
        expect(MediaFileDatabase.mock.results[0].value.addPaths).toHaveBeenCalledWith(filePaths, expect.any(Function));
    });

    test('addCommand completes successfully', async () => {
        const { MediaFileDatabase } = require('api');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that addPaths was called (main functionality)
        expect(MediaFileDatabase.mock.results[0].value.addPaths).toHaveBeenCalled();
    });

    test('addCommand gets and displays the add summary', async () => {
        const { MediaFileDatabase } = require('api');
        const utils = require('utils');

        await addCommand(['/path/to/file.jpg'], { db: '/test/db' });

        // Check that getAddSummary was called
        expect(MediaFileDatabase.mock.results[0].value.getAddSummary).toHaveBeenCalled();

        // Check that the summary details were logged (matching actual code format)
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Added 5 files to the media database.'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Summary:'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Files added:      5'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Files ignored:    1'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Files failed:     0'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Already added:    2'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Total size:       1 KiB'));
        expect(utils.log.info).toHaveBeenCalledWith(expect.stringContaining('Average size:     256 Bytes'));
    });
});