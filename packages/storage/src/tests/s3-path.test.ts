import { parseS3ListPath } from '../lib/s3-path';

describe('parseS3ListPath', () => {
    test('splits a bucket from its key', () => {
        expect(parseS3ListPath('my-bucket/some/dir')).toEqual({ bucket: 'my-bucket', key: 'some/dir' });
    });

    test('a trailing slash gives an empty key', () => {
        expect(parseS3ListPath('my-bucket/')).toEqual({ bucket: 'my-bucket', key: '' });
    });

    test('a bucket alone with no slash gives an empty key', () => {
        expect(parseS3ListPath('my-bucket')).toEqual({ bucket: 'my-bucket', key: '' });
    });

    test('keeps a leading slash in the key for the caller to normalise', () => {
        expect(parseS3ListPath('my-bucket//leading')).toEqual({ bucket: 'my-bucket', key: '/leading' });
    });

    test('rejects an empty bucket', () => {
        expect(() => parseS3ListPath('/some/dir')).toThrow();
    });

    test('rejects an empty path', () => {
        expect(() => parseS3ListPath('')).toThrow();
    });
});
