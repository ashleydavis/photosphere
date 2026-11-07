import * as path from 'path';
import { getDatabaseCacheDir, getImportRecordPath } from '../../lib/database-cache-dir';

describe('getImportRecordPath', () => {

    test('sits inside the database cache directory, beside everything else this machine works out about a database', () => {
        // The record is not in the database. It is one more thing the machine knows about it, so it
        // goes where the hash cache goes.
        expect(path.dirname(getImportRecordPath('/photos/one'))).toBe(getDatabaseCacheDir('/photos/one'));
    });

    test('names the record apart from anything else in that directory', () => {
        expect(path.basename(getImportRecordPath('/photos/one'))).toBe('imports.dat');
    });

    test('gives two databases two different records', () => {
        // Importing into one database must not show up as an import into another: each is this
        // machine's account of what it put into that database and nothing else.
        expect(getImportRecordPath('/photos/one')).not.toBe(getImportRecordPath('/photos/two'));
    });

    test('gives the same database the same record every time', () => {
        // The record has to be found again on the next run, or a restart would lose the history.
        expect(getImportRecordPath('/photos/one')).toBe(getImportRecordPath('/photos/one'));
    });

    test('makes a path out of a database path that could never be one', () => {
        // An S3 database path has colons and slashes in it, which cannot be pasted into a directory
        // name on any platform, and an S3 database is exactly the case this move was made for.
        expect(path.basename(getDatabaseCacheDir('s3:my-bucket:/photos/db'))).toMatch(/^[0-9a-f]+$/);
    });
});
