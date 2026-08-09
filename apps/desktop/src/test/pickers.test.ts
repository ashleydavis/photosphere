// Mock electron's dialog and BrowserWindow so the tests don't require a running Electron app.
const mockShowOpenDialog = jest.fn();
const mockShowSaveDialog = jest.fn();

jest.mock('electron', () => ({
    dialog: {
        showOpenDialog: mockShowOpenDialog,
        showSaveDialog: mockShowSaveDialog,
    },
}));

// Mock node-api so the tests don't touch the real desktop config file.
const mockLoadDesktopConfig = jest.fn();
const mockGetFolderPath = jest.fn();
const mockUpdateFolderPath = jest.fn();
const mockUpdateLastDownloadFolder = jest.fn();

jest.mock('node-api', () => ({
    loadDesktopConfig: mockLoadDesktopConfig,
    getFolderPath: mockGetFolderPath,
    updateFolderPath: mockUpdateFolderPath,
    updateLastDownloadFolder: mockUpdateLastDownloadFolder,
}));

import { pickFile, pickFolder } from '../lib/pickers';

describe('pickFile', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('uses lastDownloadFolder joined with the filename as the default path', async () => {
        mockLoadDesktopConfig.mockResolvedValue({ lastDownloadFolder: '/downloads' });
        mockShowSaveDialog.mockResolvedValue({ canceled: false, filePath: '/downloads/photo.jpg' });

        const result = await pickFile(null, 'photo.jpg');

        expect(result).toBe('/downloads/photo.jpg');
        expect(mockShowSaveDialog).toHaveBeenCalledWith({ defaultPath: '/downloads/photo.jpg' });
    });

    test('falls back to the filename when no last download folder is configured', async () => {
        mockLoadDesktopConfig.mockResolvedValue({});
        mockShowSaveDialog.mockResolvedValue({ canceled: false, filePath: '/elsewhere/photo.jpg' });

        const result = await pickFile(null, 'photo.jpg');

        expect(result).toBe('/elsewhere/photo.jpg');
        expect(mockShowSaveDialog).toHaveBeenCalledWith({ defaultPath: 'photo.jpg' });
    });

    test('persists the chosen folder to lastDownloadFolder on confirm', async () => {
        mockLoadDesktopConfig.mockResolvedValue({ lastDownloadFolder: '/downloads' });
        mockShowSaveDialog.mockResolvedValue({ canceled: false, filePath: '/elsewhere/photo.jpg' });

        await pickFile(null, 'photo.jpg');

        expect(mockUpdateLastDownloadFolder).toHaveBeenCalledWith('/elsewhere');
    });

    test('returns undefined and does not update config when the user cancels', async () => {
        mockLoadDesktopConfig.mockResolvedValue({ lastDownloadFolder: '/downloads' });
        mockShowSaveDialog.mockResolvedValue({ canceled: true });

        const result = await pickFile(null, 'photo.jpg');

        expect(result).toBeUndefined();
        expect(mockUpdateLastDownloadFolder).not.toHaveBeenCalled();
    });
});

describe('pickFolder', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('uses lastFolder as the default config key when no folderKey is supplied', async () => {
        mockGetFolderPath.mockResolvedValue('/photos');
        mockShowOpenDialog.mockResolvedValue({ canceled: false, filePaths: ['/new/photos'] });

        const result = await pickFolder(null);

        expect(result).toBe('/new/photos');
        expect(mockGetFolderPath).toHaveBeenCalledWith('lastFolder');
        expect(mockShowOpenDialog).toHaveBeenCalledWith({
            properties: ['openDirectory'],
            title: 'Select Folder',
            defaultPath: '/photos',
        });
        expect(mockUpdateFolderPath).toHaveBeenCalledWith('lastFolder', '/new/photos');
    });

    test('reads the default path from and persists the chosen path to the config key specified by folderKey', async () => {
        mockGetFolderPath.mockResolvedValue('/downloads');
        mockShowOpenDialog.mockResolvedValue({ canceled: false, filePaths: ['/new/downloads'] });

        const result = await pickFolder(null, { folderKey: 'lastDownloadFolder' });

        expect(result).toBe('/new/downloads');
        expect(mockGetFolderPath).toHaveBeenCalledWith('lastDownloadFolder');
        expect(mockShowOpenDialog).toHaveBeenCalledWith({
            properties: ['openDirectory'],
            title: 'Select Folder',
            defaultPath: '/downloads',
        });
        expect(mockUpdateFolderPath).toHaveBeenCalledWith('lastDownloadFolder', '/new/downloads');
    });

    test('passes through the title and createDirectory options to the dialog', async () => {
        mockGetFolderPath.mockResolvedValue(undefined);
        mockShowOpenDialog.mockResolvedValue({ canceled: false, filePaths: ['/new/db'] });

        await pickFolder(null, { title: 'Create Database', createDirectory: true });

        expect(mockShowOpenDialog).toHaveBeenCalledWith({
            properties: ['openDirectory', 'createDirectory'],
            title: 'Create Database',
            defaultPath: undefined,
        });
    });

    test('returns undefined and does not persist config when the user cancels', async () => {
        mockGetFolderPath.mockResolvedValue('/photos');
        mockShowOpenDialog.mockResolvedValue({ canceled: true, filePaths: [] });

        const result = await pickFolder(null);

        expect(result).toBeUndefined();
        expect(mockUpdateFolderPath).not.toHaveBeenCalled();
    });
});
