import * as path from 'path';
import * as fsNative from 'fs/promises';
import { writeFileSync } from 'fs';
import { readToml, writeToml, readJson, writeJson, outputFile, updateToml, updateJson, updateFileOptimistic, updateFileRawOptimistic, getProcessTmpDir } from '../../lib/fs';

//
// Simple config shape used by the update-mutator tests.
//
interface ICounter {
    // A running count the mutator increments.
    count: number;
}

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

describe('outputFile atomic write', () => {
    test('concurrent writes to the same file never leave a torn result', async () => {
        const filePath = tempFilePath('atomic-concurrent.txt');
        // Each writer emits content of a different length so a byte-level interleave
        // would produce a mix that matches none of the inputs. Distinct lengths make
        // any torn write detectable.
        const contents = Array.from({ length: 20 }, (_, index) => `value-${index}-${'x'.repeat(index)}`);

        await Promise.all(contents.map(content => outputFile(filePath, content, { encoding: 'utf8' })));

        const finalContent = (await fsNative.readFile(filePath, { encoding: 'utf8' })).toString();
        // The file must equal exactly one of the complete writes, never a fragment or a blend.
        expect(contents).toContain(finalContent);

        await fsNative.unlink(filePath);
    });

    test('leaves no temporary files behind after writing', async () => {
        const filePath = tempFilePath('atomic-cleanup.txt');

        await outputFile(filePath, 'done', { encoding: 'utf8' });

        const dirEntries = await fsNative.readdir(path.dirname(filePath));
        const baseName = path.basename(filePath);
        const leftoverTempFiles = dirEntries.filter(entry => entry.startsWith(`${baseName}.tmp-`));
        expect(leftoverTempFiles).toEqual([]);

        await fsNative.unlink(filePath);
    });
});

describe('updateToml optimistic read-modify-write', () => {
    test('uses the fallback and writes when the file does not exist', async () => {
        const filePath = tempFilePath('update-toml-new.toml');

        await updateToml<Record<string, number>>(filePath, { count: 0 }, current => ({ count: current.count + 5 }));

        const result = await readToml<ICounter>(filePath);
        expect(result.count).toBe(5);

        await fsNative.unlink(filePath);
    });

    test('reads existing contents and applies the mutator', async () => {
        const filePath = tempFilePath('update-toml-existing.toml');
        await writeToml(filePath, { count: 10 });

        await updateToml<Record<string, number>>(filePath, { count: 0 }, current => ({ count: current.count + 1 }));

        const result = await readToml<ICounter>(filePath);
        expect(result.count).toBe(11);

        await fsNative.unlink(filePath);
    });

    test('reloads and re-applies the mutator when the file changed under it', async () => {
        const filePath = tempFilePath('update-toml-retry.toml');
        await writeToml(filePath, { count: 0 });
        let injected = false;

        await updateToml<Record<string, number>>(filePath, { count: 0 }, current => {
            if (!injected) {
                injected = true;
                // Simulate a concurrent writer changing the file after our read but before the pre-move check.
                writeFileSync(filePath, 'count = 99\n');
            }
            return { count: current.count + 1 };
        }, 3);

        // The mutator ran twice: once on the stale read (discarded), once on the reloaded value 99 -> 100.
        const result = await readToml<ICounter>(filePath);
        expect(result.count).toBe(100);

        await fsNative.unlink(filePath);
    });

    test('throws after the configured retries when the file keeps changing', async () => {
        const filePath = tempFilePath('update-toml-exhaust.toml');
        await writeToml(filePath, { count: 0 });
        let external = 1;

        await expect(updateToml<Record<string, number>>(filePath, { count: 0 }, current => {
            // Change the file under every attempt (growing its size) so the pre-move check always
            // sees a conflict regardless of mtime resolution.
            writeFileSync(filePath, `count = ${external}\n${'# pad\n'.repeat(external)}`);
            external += 1;
            return { count: current.count + 1 };
        }, 2)).rejects.toThrow(/kept changing/);

        await fsNative.unlink(filePath);
    });
});

describe('updateJson optimistic read-modify-write', () => {
    test('uses the fallback and writes when the file does not exist', async () => {
        const filePath = tempFilePath('update-json-new.json');

        await updateJson<ICounter>(filePath, { count: 0 }, current => ({ count: current.count + 5 }));

        const result = await readJson<ICounter>(filePath);
        expect(result.count).toBe(5);

        await fsNative.unlink(filePath);
    });

    test('reads existing contents and applies the mutator', async () => {
        const filePath = tempFilePath('update-json-existing.json');
        await writeJson(filePath, { count: 10 });

        await updateJson<ICounter>(filePath, { count: 0 }, current => ({ count: current.count + 1 }));

        const result = await readJson<ICounter>(filePath);
        expect(result.count).toBe(11);

        await fsNative.unlink(filePath);
    });

    test('reloads and re-applies the mutator when the file changed under it', async () => {
        const filePath = tempFilePath('update-json-retry.json');
        await writeJson(filePath, { count: 0 });
        let injected = false;

        await updateJson<ICounter>(filePath, { count: 0 }, current => {
            if (!injected) {
                injected = true;
                writeFileSync(filePath, JSON.stringify({ count: 99 }));
            }
            return { count: current.count + 1 };
        }, 3);

        const result = await readJson<ICounter>(filePath);
        expect(result.count).toBe(100);

        await fsNative.unlink(filePath);
    });

    test('throws after the configured retries when the file keeps changing', async () => {
        const filePath = tempFilePath('update-json-exhaust.json');
        await writeJson(filePath, { count: 0 });
        let external = 1;

        await expect(updateJson<ICounter>(filePath, { count: 0 }, current => {
            // Grow the file each attempt so the pre-move check always sees a conflict.
            writeFileSync(filePath, JSON.stringify({ count: external, pad: 'x'.repeat(external) }));
            external += 1;
            return { count: current.count + 1 };
        }, 2)).rejects.toThrow(/kept changing/);

        await fsNative.unlink(filePath);
    });
});

describe('updateFileOptimistic', () => {
    test('uses the fallback, applies the mutator, and serializes the result', async () => {
        const filePath = tempFilePath('optimistic-generic.txt');

        // Identity parse/serialize so the test exercises the core loop independent of any format.
        await updateFileOptimistic<string>(filePath, 'seed', current => `${current}-mutated`, raw => raw, value => value, 3);

        const content = (await fsNative.readFile(filePath, { encoding: 'utf8' })).toString();
        expect(content).toBe('seed-mutated');

        await fsNative.unlink(filePath);
    });

    test('reloads and re-applies the mutator when the file changed under it', async () => {
        const filePath = tempFilePath('optimistic-generic-retry.txt');
        await outputFile(filePath, 'base', { encoding: 'utf8' });
        let injected = false;

        await updateFileOptimistic<string>(filePath, '', current => {
            if (!injected) {
                injected = true;
                // Simulate a concurrent writer changing the file after our read, before the check.
                writeFileSync(filePath, 'changed-by-other');
            }
            return `${current}!`;
        }, raw => raw, value => value, 3);

        const content = (await fsNative.readFile(filePath, { encoding: 'utf8' })).toString();
        expect(content).toBe('changed-by-other!');

        await fsNative.unlink(filePath);
    });

    test('throws after the configured retries when the file keeps changing', async () => {
        const filePath = tempFilePath('optimistic-generic-exhaust.txt');
        await outputFile(filePath, 'x', { encoding: 'utf8' });
        let external = 1;

        await expect(updateFileOptimistic<string>(filePath, '', current => {
            // Grow the file each attempt to a size that always differs from the current file,
            // so the pre-move check always sees a conflict regardless of timestamp resolution.
            writeFileSync(filePath, 'y'.repeat(external + 4));
            external += 1;
            return `${current}!`;
        }, raw => raw, value => value, 2)).rejects.toThrow(/kept changing/);

        await fsNative.unlink(filePath);
    });
});

describe('updateFileRawOptimistic', () => {
    test('passes undefined for a missing file and writes the mutator result', async () => {
        const filePath = tempFilePath('optimistic-raw-create.bin');
        let receivedCurrent: Buffer | undefined = Buffer.alloc(0);

        // Bytes that are not valid utf8, proving the raw path never decodes the content.
        const newBytes = Buffer.from([0x00, 0xff, 0xfe, 0x01]);
        await updateFileRawOptimistic(filePath, current => {
            receivedCurrent = current;
            return newBytes;
        }, 3);

        expect(receivedCurrent).toBeUndefined();
        const written = await fsNative.readFile(filePath);
        expect(written.equals(newBytes)).toBe(true);

        await fsNative.unlink(filePath);
    });

    test('passes the existing bytes to the mutator and publishes its result', async () => {
        const filePath = tempFilePath('optimistic-raw-update.bin');
        const originalBytes = Buffer.from([0x10, 0x20, 0x30]);
        await outputFile(filePath, originalBytes);

        await updateFileRawOptimistic(filePath, current => {
            expect(current).toBeDefined();
            expect(current!.equals(originalBytes)).toBe(true);
            return Buffer.concat([current!, Buffer.from([0x40])]);
        }, 3);

        const written = await fsNative.readFile(filePath);
        expect(written.equals(Buffer.from([0x10, 0x20, 0x30, 0x40]))).toBe(true);

        await fsNative.unlink(filePath);
    });

    test('reloads and re-applies the mutator when the file changed under it', async () => {
        const filePath = tempFilePath('optimistic-raw-retry.bin');
        await outputFile(filePath, Buffer.from('base'));
        let injected = false;

        await updateFileRawOptimistic(filePath, current => {
            if (!injected) {
                injected = true;
                // Simulate a concurrent writer changing the file after our read, before the check.
                writeFileSync(filePath, 'changed-by-other');
            }
            return Buffer.concat([current || Buffer.alloc(0), Buffer.from('!')]);
        }, 3);

        const written = await fsNative.readFile(filePath);
        expect(written.toString('utf8')).toBe('changed-by-other!');

        await fsNative.unlink(filePath);
    });

    test('throws after the configured retries when the file keeps changing', async () => {
        const filePath = tempFilePath('optimistic-raw-exhaust.bin');
        await outputFile(filePath, Buffer.from('x'));
        let external = 1;

        await expect(updateFileRawOptimistic(filePath, current => {
            // Grow the file each attempt to a size that always differs from the current file,
            // so the pre-move check always sees a conflict regardless of timestamp resolution.
            writeFileSync(filePath, 'y'.repeat(external + 4));
            external += 1;
            return Buffer.concat([current || Buffer.alloc(0), Buffer.from('!')]);
        }, 2)).rejects.toThrow(/kept changing/);

        await fsNative.unlink(filePath);
    });
});
