import * as path from 'path';
import * as fsNative from 'fs/promises';
import { readToml, writeToml, getProcessTmpDir } from '../../lib/fs';

//
// Creates a unique temp file path in the OS temp directory.
//
function tempFilePath(suffix: string): string {
    return path.join(getProcessTmpDir(), `photosphere-fs-test-${Date.now()}-${suffix}`);
}

describe('readToml / writeToml', () => {
    test('round-trips a flat object', async () => {
        const filePath = tempFilePath('flat.toml');
        const original = { name: 'test', count: 42, flag: true };

        await writeToml(filePath, original);
        const result = await readToml<typeof original>(filePath);

        expect(result.name).toBe('test');
        expect(result.count).toBe(42);
        expect(result.flag).toBe(true);

        await fsNative.unlink(filePath);
    });

    test('round-trips an object with string arrays', async () => {
        const filePath = tempFilePath('arrays.toml');
        const original = { tags: ['alpha', 'beta', 'gamma'] };

        await writeToml(filePath, original);
        const result = await readToml<typeof original>(filePath);

        expect(result.tags).toEqual(['alpha', 'beta', 'gamma']);

        await fsNative.unlink(filePath);
    });

    test('round-trips a nested object (array of tables)', async () => {
        const filePath = tempFilePath('nested.toml');
        const original = { items: [{ name: 'a', value: 1 }, { name: 'b', value: 2 }] };

        await writeToml(filePath, original);
        const result = await readToml<typeof original>(filePath);

        expect(result.items).toHaveLength(2);
        expect(result.items[0].name).toBe('a');
        expect(result.items[1].value).toBe(2);

        await fsNative.unlink(filePath);
    });

    test('writeToml creates parent directories if missing', async () => {
        const filePath = tempFilePath('subdir/nested.toml');
        const original = { key: 'value' };

        await writeToml(filePath, original);
        const result = await readToml<typeof original>(filePath);

        expect(result.key).toBe('value');

        await fsNative.rm(path.dirname(filePath), { recursive: true });
    });
});
