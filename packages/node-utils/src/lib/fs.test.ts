import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs/promises';
import {
    ensureDir,
    ensureFileDir,
    pathExists,
    remove,
    outputFile,
    readJson,
    writeJson,
    emptyDir,
    copy,
    ensureDirSync,
    removeSync,
    copySync
} from './fs';

describe('fs utilities', () => {
    let testDir: string;

    beforeEach(async () => {
        // Create a unique test directory for each test
        testDir = path.join(os.tmpdir(), `fs-test-${Date.now()}-${Math.random().toString(36).substring(7)}`);
        await ensureDir(testDir);
    });

    afterEach(async () => {
        // Clean up test directory
        try {
            await remove(testDir);
        } catch (error) {
            // Ignore cleanup errors
        }
    });

    describe('ensureDir', () => {
        it('should create a directory if it does not exist', async () => {
            const dirPath = path.join(testDir, 'new-dir');
            await ensureDir(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
            
            const stats = await fs.stat(dirPath);
            expect(stats.isDirectory()).toBe(true);
        });

        it('should create nested directories recursively', async () => {
            const dirPath = path.join(testDir, 'nested', 'deep', 'directory');
            await ensureDir(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
        });

        it('should not throw if directory already exists', async () => {
            const dirPath = path.join(testDir, 'existing-dir');
            await ensureDir(dirPath);
            await ensureDir(dirPath); // Should not throw
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
        });

        it('should throw if path exists as a file', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await fs.writeFile(filePath, 'test');
            
            await expect(ensureDir(filePath)).rejects.toThrow('Path exists but is not a directory');
        });
    });

    describe('ensureFileDir', () => {
        it('should create parent directory for a file path', async () => {
            const filePath = path.join(testDir, 'parent', 'child', 'file.txt');
            await ensureFileDir(filePath);
            
            const parentDir = path.dirname(filePath);
            const exists = await pathExists(parentDir);
            expect(exists).toBe(true);
            
            const stats = await fs.stat(parentDir);
            expect(stats.isDirectory()).toBe(true);
        });

        it('should handle file in root directory', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await ensureFileDir(filePath);
            
            // Should not throw and parent should exist (testDir)
            const exists = await pathExists(testDir);
            expect(exists).toBe(true);
        });
    });

    describe('pathExists', () => {
        it('should return true for existing file', async () => {
            const filePath = path.join(testDir, 'test.txt');
            await fs.writeFile(filePath, 'test');
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(true);
        });

        it('should return true for existing directory', async () => {
            const dirPath = path.join(testDir, 'test-dir');
            await ensureDir(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
        });

        it('should return false for non-existent path', async () => {
            const filePath = path.join(testDir, 'non-existent.txt');
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(false);
        });
    });

    describe('remove', () => {
        it('should remove a file', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await fs.writeFile(filePath, 'test');
            
            await remove(filePath);
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(false);
        });

        it('should remove a directory recursively', async () => {
            const dirPath = path.join(testDir, 'dir');
            await ensureDir(dirPath);
            await fs.writeFile(path.join(dirPath, 'file.txt'), 'test');
            
            await remove(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(false);
        });

        it('should not throw if file does not exist', async () => {
            const filePath = path.join(testDir, 'non-existent.txt');
            
            await expect(remove(filePath)).resolves.not.toThrow();
        });

        it('should remove nested directory structure', async () => {
            const dirPath = path.join(testDir, 'nested', 'deep', 'dir');
            await ensureDir(dirPath);
            await fs.writeFile(path.join(dirPath, 'file.txt'), 'test');
            
            await remove(path.join(testDir, 'nested'));
            
            const exists = await pathExists(path.join(testDir, 'nested'));
            expect(exists).toBe(false);
        });
    });

    describe('outputFile', () => {
        it('should create file and parent directories', async () => {
            const filePath = path.join(testDir, 'parent', 'child', 'file.txt');
            const content = 'test content';
            
            await outputFile(filePath, content);
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(true);
            
            const data = await fs.readFile(filePath, 'utf8');
            expect(data).toBe(content);
        });

        it('should write Buffer data', async () => {
            const filePath = path.join(testDir, 'buffer.txt');
            const content = Buffer.from('buffer content');
            
            await outputFile(filePath, content);
            
            const data = await fs.readFile(filePath);
            expect(data).toEqual(content);
        });

        it('should overwrite existing file', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await fs.writeFile(filePath, 'old content');
            
            await outputFile(filePath, 'new content');
            
            const data = await fs.readFile(filePath, 'utf8');
            expect(data).toBe('new content');
        });
    });

    describe('readJson', () => {
        it('should read and parse JSON file', async () => {
            const filePath = path.join(testDir, 'data.json');
            const data = { name: 'test', value: 123 };
            await fs.writeFile(filePath, JSON.stringify(data));
            
            const result = await readJson(filePath);
            
            expect(result).toEqual(data);
        });

        it('should read JSON with custom encoding', async () => {
            const filePath = path.join(testDir, 'data.json');
            const data = { name: 'test' };
            await fs.writeFile(filePath, JSON.stringify(data), { encoding: 'utf8' });
            
            const result = await readJson(filePath, { encoding: 'utf8' });
            
            expect(result).toEqual(data);
        });

        it('should throw if file does not exist', async () => {
            const filePath = path.join(testDir, 'non-existent.json');
            
            await expect(readJson(filePath)).rejects.toThrow();
        });

        it('should throw if file contains invalid JSON', async () => {
            const filePath = path.join(testDir, 'invalid.json');
            await fs.writeFile(filePath, 'not valid json');
            
            await expect(readJson(filePath)).rejects.toThrow();
        });
    });

    describe('writeJson', () => {
        it('should write object as JSON file', async () => {
            const filePath = path.join(testDir, 'data.json');
            const data = { name: 'test', value: 123 };
            
            await writeJson(filePath, data);
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(true);
            
            const content = await fs.readFile(filePath, 'utf8');
            const parsed = JSON.parse(content);
            expect(parsed).toEqual(data);
        });

        it('should create parent directories', async () => {
            const filePath = path.join(testDir, 'parent', 'child', 'data.json');
            const data = { name: 'test' };
            
            await writeJson(filePath, data);
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(true);
        });

        it('should format JSON with spaces', async () => {
            const filePath = path.join(testDir, 'data.json');
            const data = { name: 'test' };
            
            await writeJson(filePath, data, { spaces: 2 });
            
            const content = await fs.readFile(filePath, 'utf8');
            expect(content).toContain('\n');
            expect(content).toContain('  '); // 2 spaces indentation
        });

        it('should handle nested objects', async () => {
            const filePath = path.join(testDir, 'data.json');
            const data = { 
                name: 'test', 
                nested: { 
                    value: 123,
                    array: [1, 2, 3]
                } 
            };
            
            await writeJson(filePath, data);
            
            const result = await readJson(filePath);
            expect(result).toEqual(data);
        });
    });

    describe('emptyDir', () => {
        it('should create directory if it does not exist', async () => {
            const dirPath = path.join(testDir, 'empty-dir');
            
            await emptyDir(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
            
            const entries = await fs.readdir(dirPath);
            expect(entries.length).toBe(0);
        });

        it('should remove all files from directory', async () => {
            const dirPath = path.join(testDir, 'dir');
            await ensureDir(dirPath);
            await fs.writeFile(path.join(dirPath, 'file1.txt'), 'test1');
            await fs.writeFile(path.join(dirPath, 'file2.txt'), 'test2');
            
            await emptyDir(dirPath);
            
            const entries = await fs.readdir(dirPath);
            expect(entries.length).toBe(0);
        });

        it('should remove nested directories', async () => {
            const dirPath = path.join(testDir, 'dir');
            await ensureDir(dirPath);
            await ensureDir(path.join(dirPath, 'nested'));
            await fs.writeFile(path.join(dirPath, 'nested', 'file.txt'), 'test');
            
            await emptyDir(dirPath);
            
            const entries = await fs.readdir(dirPath);
            expect(entries.length).toBe(0);
        });

        it('should keep directory itself', async () => {
            const dirPath = path.join(testDir, 'dir');
            await ensureDir(dirPath);
            await fs.writeFile(path.join(dirPath, 'file.txt'), 'test');
            
            await emptyDir(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(true);
        });
    });

    describe('copy', () => {
        it('should copy a file', async () => {
            const srcPath = path.join(testDir, 'source.txt');
            const destPath = path.join(testDir, 'dest.txt');
            const content = 'test content';
            await fs.writeFile(srcPath, content);
            
            await copy(srcPath, destPath);
            
            const exists = await pathExists(destPath);
            expect(exists).toBe(true);
            
            const data = await fs.readFile(destPath, 'utf8');
            expect(data).toBe(content);
        });

        it('should copy a directory recursively', async () => {
            const srcDir = path.join(testDir, 'source');
            const destDir = path.join(testDir, 'dest');
            await ensureDir(srcDir);
            await fs.writeFile(path.join(srcDir, 'file1.txt'), 'test1');
            await ensureDir(path.join(srcDir, 'nested'));
            await fs.writeFile(path.join(srcDir, 'nested', 'file2.txt'), 'test2');
            
            await copy(srcDir, destDir);
            
            const exists = await pathExists(destDir);
            expect(exists).toBe(true);
            
            const file1Exists = await pathExists(path.join(destDir, 'file1.txt'));
            expect(file1Exists).toBe(true);
            
            const file2Exists = await pathExists(path.join(destDir, 'nested', 'file2.txt'));
            expect(file2Exists).toBe(true);
            
            const file1Content = await fs.readFile(path.join(destDir, 'file1.txt'), 'utf8');
            expect(file1Content).toBe('test1');
            
            const file2Content = await fs.readFile(path.join(destDir, 'nested', 'file2.txt'), 'utf8');
            expect(file2Content).toBe('test2');
        });

        it('should create parent directories for destination', async () => {
            const srcPath = path.join(testDir, 'source.txt');
            const destPath = path.join(testDir, 'parent', 'child', 'dest.txt');
            await fs.writeFile(srcPath, 'test');
            
            await copy(srcPath, destPath);
            
            const exists = await pathExists(destPath);
            expect(exists).toBe(true);
        });

        it('should overwrite existing file', async () => {
            const srcPath = path.join(testDir, 'source.txt');
            const destPath = path.join(testDir, 'dest.txt');
            await fs.writeFile(srcPath, 'new content');
            await fs.writeFile(destPath, 'old content');
            
            await copy(srcPath, destPath);
            
            const data = await fs.readFile(destPath, 'utf8');
            expect(data).toBe('new content');
        });
    });

    describe('ensureDirSync', () => {
        it('should create a directory synchronously', () => {
            const dirPath = path.join(testDir, 'sync-dir');
            
            ensureDirSync(dirPath);
            
            const exists = require('fs').existsSync(dirPath);
            expect(exists).toBe(true);
            
            const stats = require('fs').statSync(dirPath);
            expect(stats.isDirectory()).toBe(true);
        });

        it('should create nested directories recursively', () => {
            const dirPath = path.join(testDir, 'nested', 'deep', 'sync-dir');
            
            ensureDirSync(dirPath);
            
            const exists = require('fs').existsSync(dirPath);
            expect(exists).toBe(true);
        });

        it('should not throw if directory already exists', () => {
            const dirPath = path.join(testDir, 'existing-sync-dir');
            ensureDirSync(dirPath);
            
            expect(() => ensureDirSync(dirPath)).not.toThrow();
        });

        it('should throw if path exists as a file', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await fs.writeFile(filePath, 'test');
            
            expect(() => ensureDirSync(filePath)).toThrow('Path exists but is not a directory');
        });
    });

    describe('removeSync', () => {
        it('should remove a file synchronously', async () => {
            const filePath = path.join(testDir, 'file.txt');
            await fs.writeFile(filePath, 'test');
            
            removeSync(filePath);
            
            const exists = await pathExists(filePath);
            expect(exists).toBe(false);
        });

        it('should remove a directory synchronously', async () => {
            const dirPath = path.join(testDir, 'dir');
            await ensureDir(dirPath);
            await fs.writeFile(path.join(dirPath, 'file.txt'), 'test');
            
            removeSync(dirPath);
            
            const exists = await pathExists(dirPath);
            expect(exists).toBe(false);
        });

        it('should not throw if file does not exist', () => {
            const filePath = path.join(testDir, 'non-existent.txt');
            
            expect(() => removeSync(filePath)).not.toThrow();
        });
    });

    describe('copySync', () => {
        it('should copy a file synchronously', async () => {
            const srcPath = path.join(testDir, 'source.txt');
            const destPath = path.join(testDir, 'dest.txt');
            const content = 'test content';
            await fs.writeFile(srcPath, content);
            
            copySync(srcPath, destPath);
            
            const exists = await pathExists(destPath);
            expect(exists).toBe(true);
            
            const data = await fs.readFile(destPath, 'utf8');
            expect(data).toBe(content);
        });

        it('should copy a directory synchronously', async () => {
            const srcDir = path.join(testDir, 'source');
            const destDir = path.join(testDir, 'dest');
            await ensureDir(srcDir);
            await fs.writeFile(path.join(srcDir, 'file1.txt'), 'test1');
            await ensureDir(path.join(srcDir, 'nested'));
            await fs.writeFile(path.join(srcDir, 'nested', 'file2.txt'), 'test2');
            
            copySync(srcDir, destDir);
            
            const exists = await pathExists(destDir);
            expect(exists).toBe(true);
            
            const file1Exists = await pathExists(path.join(destDir, 'file1.txt'));
            expect(file1Exists).toBe(true);
            
            const file2Exists = await pathExists(path.join(destDir, 'nested', 'file2.txt'));
            expect(file2Exists).toBe(true);
        });

        it('should create parent directories for destination', () => {
            const srcPath = path.join(testDir, 'source.txt');
            const destPath = path.join(testDir, 'parent', 'child', 'dest.txt');
            require('fs').writeFileSync(srcPath, 'test');
            
            copySync(srcPath, destPath);
            
            const exists = require('fs').existsSync(destPath);
            expect(exists).toBe(true);
        });
    });
});

