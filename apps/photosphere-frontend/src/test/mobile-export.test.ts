import { buildExportFilePath, buildExportFolderPath, EXPORT_TEMP_DIR, sanitizePathSegment, saveDownloadsViaShareSheet, buildExportFileRequest, buildExportFilesRequest, type ExportTestOutcome, type IMobileExportDependencies } from '../lib/mobile-export';
import { TaskStatus, type ITaskResult } from 'task-queue';

describe('sanitizePathSegment', () => {
    test('keeps a plain name', () => {
        expect(sanitizePathSegment('photo.jpg', 'fallback')).toBe('photo.jpg');
    });

    test('keeps only the last component of a path with either separator', () => {
        expect(sanitizePathSegment('a/b/photo.jpg', 'fallback')).toBe('photo.jpg');
        expect(sanitizePathSegment('a\\b\\photo.jpg', 'fallback')).toBe('photo.jpg');
    });

    test('trims whitespace', () => {
        expect(sanitizePathSegment('  photo.jpg  ', 'fallback')).toBe('photo.jpg');
    });

    test('falls back for a name that is empty, a dot, two dots or ends in a separator', () => {
        expect(sanitizePathSegment('', 'fallback')).toBe('fallback');
        expect(sanitizePathSegment('   ', 'fallback')).toBe('fallback');
        expect(sanitizePathSegment('.', 'fallback')).toBe('fallback');
        expect(sanitizePathSegment('..', 'fallback')).toBe('fallback');
        expect(sanitizePathSegment('../..', 'fallback')).toBe('fallback');
        expect(sanitizePathSegment('folder/', 'fallback')).toBe('fallback');
    });
});

describe('buildExportFilePath', () => {
    test('puts the file in a folder of its own under the export directory', () => {
        expect(buildExportFilePath('photo.jpg', 'abc')).toBe(`${EXPORT_TEMP_DIR}/abc/photo.jpg`);
    });

    test('cannot escape the folder with a traversing name', () => {
        expect(buildExportFilePath('../../etc/passwd', 'abc')).toBe(`${EXPORT_TEMP_DIR}/abc/passwd`);
    });

    test('names an unnameable file download', () => {
        expect(buildExportFilePath('..', 'abc')).toBe(`${EXPORT_TEMP_DIR}/abc/download`);
    });
});

describe('buildExportFolderPath', () => {
    test('is a folder of its own under the export directory', () => {
        expect(buildExportFolderPath('abc')).toBe(`${EXPORT_TEMP_DIR}/abc`);
    });
});

//
// A task the stand-in ran.
//
interface IRecordedTask {
    // The task type.
    taskType: string;

    // The input it was given.
    data: object;
}

//
// A set of stand-ins for what saving a download needs, which records what it was asked.
//
interface IRecordedExport {
    // The dependencies to hand to the function under test.
    dependencies: IMobileExportDependencies;

    // Each task that was run, with its type.
    tasks: IRecordedTask[];

    // The paths handed to the share sheet, one entry per sheet.
    exported: string[][];

    // The test outcome each sheet was asked with, one entry per sheet.
    outcomes: (ExportTestOutcome | undefined)[];

    // Each export folder the shell was asked to make.
    folders: string[];
}

function recordExport(taskResult: ITaskResult, exportFileReply: { path: string | null }, exportFilesReply: { paths: string[] | null }): IRecordedExport {
    const recorded: IRecordedExport = {
        tasks: [],
        exported: [],
        outcomes: [],
        folders: [],
        dependencies: {
            newUuid: () => 'uuid-1',
            makeExportFolder: async folder => {
                recorded.folders.push(folder);
                return `/files/${folder}`;
            },
            runTask: async (taskType, data) => {
                recorded.tasks.push({ taskType, data });
                return taskResult;
            },
            exportFile: async (path, testOutcome) => {
                recorded.outcomes.push(testOutcome);
                recorded.exported.push([path]);
                return exportFileReply;
            },
            exportFiles: async (paths, testOutcome) => {
                recorded.outcomes.push(testOutcome);
                recorded.exported.push(paths);
                return exportFilesReply;
            },
        },
    };
    return recorded;
}

function succeeded(outputs: object): ITaskResult {
    return { taskId: 't', type: 'x', inputs: {}, status: TaskStatus.Succeeded, outputs };
}

function failed(errorMessage: string): ITaskResult {
    return { taskId: 't', type: 'x', inputs: {}, status: TaskStatus.Failed, errorMessage };
}

describe('saveDownloadsViaShareSheet', () => {
    const items = [
        { assetId: 'a1', assetType: 'asset', filename: 'one.jpg' },
        { assetId: 'a2', assetType: 'asset', filename: 'two.jpg' },
    ];

    test('one file is written to a temporary path and handed out', async () => {
        const recorded = recordExport(succeeded({}), { path: '.export-tmp/uuid-1/one.jpg' }, { paths: null });

        const result = await saveDownloadsViaShareSheet([items[0]], '/db', undefined, recorded.dependencies);

        expect(recorded.tasks).toEqual([
            { taskType: 'save-asset', data: { assetId: 'a1', assetType: 'asset', destPath: '/files/.export-tmp/uuid-1/one.jpg', databasePath: '/db' } },
        ]);
        expect(recorded.folders).toEqual(['.export-tmp/uuid-1']);
        expect(recorded.exported).toEqual([['.export-tmp/uuid-1/one.jpg']]);
        expect(result).toEqual({ outcome: 'saved', savedCount: 1, failedCount: 0 });
    });

    test('a dismissed sheet for one file is a cancelled save', async () => {
        const recorded = recordExport(succeeded({}), { path: null }, { paths: null });

        const result = await saveDownloadsViaShareSheet([items[0]], '/db', undefined, recorded.dependencies);

        expect(result).toEqual({ outcome: 'cancelled', savedCount: 0, failedCount: 0 });
    });

    test('a failed write of one file is a failed save and shows no sheet', async () => {
        const recorded = recordExport(failed('disk full'), { path: 'x' }, { paths: null });

        const result = await saveDownloadsViaShareSheet([items[0]], '/db', undefined, recorded.dependencies);

        expect(recorded.exported).toEqual([]);
        expect(result).toEqual({ outcome: 'failed', savedCount: 0, failedCount: 1, errorMessage: 'disk full' });
    });

    test('several files are written into a temporary folder and handed out through one sheet', async () => {
        const recorded = recordExport(succeeded({ succeededFiles: ['one.jpg', 'two.jpg'], failedFiles: [] }), { path: null }, { paths: ['x'] });

        const result = await saveDownloadsViaShareSheet(items, '/db', undefined, recorded.dependencies);

        expect(recorded.tasks).toEqual([
            { taskType: 'save-assets-batch', data: { assets: items, folderPath: '/files/.export-tmp/uuid-1', databasePath: '/db' } },
        ]);
        expect(recorded.exported).toEqual([['.export-tmp/uuid-1/one.jpg', '.export-tmp/uuid-1/two.jpg']]);
        expect(result).toEqual({ outcome: 'saved', savedCount: 2, failedCount: 0 });
    });

    test('a batch that partly failed reports both counts', async () => {
        const recorded = recordExport(succeeded({ succeededFiles: ['one.jpg'], failedFiles: ['two.jpg'] }), { path: null }, { paths: ['x'] });

        const result = await saveDownloadsViaShareSheet(items, '/db', undefined, recorded.dependencies);

        expect(result).toEqual({ outcome: 'saved', savedCount: 1, failedCount: 1 });
    });

    test('a dismissed sheet for several files is a cancelled save', async () => {
        const recorded = recordExport(succeeded({ succeededFiles: ['one.jpg', 'two.jpg'], failedFiles: [] }), { path: null }, { paths: null });

        const result = await saveDownloadsViaShareSheet(items, '/db', undefined, recorded.dependencies);

        expect(result).toEqual({ outcome: 'cancelled', savedCount: 0, failedCount: 0 });
    });

    test('a batch where every file failed shows no sheet and reports the failures', async () => {
        const recorded = recordExport(succeeded({ succeededFiles: [], failedFiles: ['one.jpg', 'two.jpg'] }), { path: null }, { paths: ['x'] });

        const result = await saveDownloadsViaShareSheet(items, '/db', undefined, recorded.dependencies);

        expect(recorded.exported).toEqual([]);
        expect(result).toEqual({ outcome: 'saved', savedCount: 0, failedCount: 2 });
    });

    test('a failed batch task is a failed save', async () => {
        const recorded = recordExport(failed('no database'), { path: null }, { paths: null });

        const result = await saveDownloadsViaShareSheet(items, '/db', undefined, recorded.dependencies);

        expect(recorded.exported).toEqual([]);
        expect(result).toEqual({ outcome: 'failed', savedCount: 0, failedCount: 2, errorMessage: 'no database' });
    });
});

describe('a staged test outcome', () => {
    const items = [
        { assetId: 'a1', assetType: 'asset', filename: 'one.jpg' },
        { assetId: 'a2', assetType: 'asset', filename: 'two.jpg' },
    ];

    test('is handed to the sheet for one file', async () => {
        const recorded = recordExport(succeeded({}), { path: '.export-tmp/uuid-1/one.jpg' }, { paths: null });

        await saveDownloadsViaShareSheet([items[0]], '/db', 'shared', recorded.dependencies);

        expect(recorded.outcomes).toEqual(['shared']);
    });

    test('is handed to the sheet for several files', async () => {
        const recorded = recordExport(succeeded({ succeededFiles: ['one.jpg', 'two.jpg'], failedFiles: [] }), { path: null }, { paths: ['x'] });

        await saveDownloadsViaShareSheet(items, '/db', 'cancelled', recorded.dependencies);

        expect(recorded.outcomes).toEqual(['cancelled']);
    });

    test('travels in the request only when one is staged', () => {
        expect(buildExportFileRequest('p', undefined)).toEqual({ path: 'p' });
        expect(buildExportFileRequest('p', 'shared')).toEqual({ path: 'p', testOutcome: 'shared' });
        expect(buildExportFilesRequest(['p'], undefined)).toEqual({ paths: ['p'] });
        expect(buildExportFilesRequest(['p'], 'cancelled')).toEqual({ paths: ['p'], testOutcome: 'cancelled' });
    });
});
