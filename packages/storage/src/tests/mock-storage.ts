import { Readable } from 'stream';
import { IFileInfo, IListResult, IStorage } from '../lib/storage';

// Mock IStorage implementation for testing
export class MockStorage implements IStorage {
    private files: Map<string, { data: Buffer, contentType?: string }> = new Map();
    private directories: Set<string> = new Set();
    
    constructor(public readonly location: string = "memory://mock") {}

    async isEmpty(path: string): Promise<boolean> {
        const hasSubDirs = Array.from(this.directories).some(dir => 
            dir !== path && dir.startsWith(path + '/'));
        
        const hasFiles = Array.from(this.files.keys()).some(file => 
            file.startsWith(path + '/'));
            
        return !hasSubDirs && !hasFiles;
    }

    async read(filePath: string): Promise<Buffer | undefined> {
        const file = this.files.get(filePath);
        return file?.data;
    }

    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, { data, contentType });
        
        // Extract directory path and ensure it exists
        const dirPath = filePath.substring(0, filePath.lastIndexOf('/'));
        if (dirPath) {
            this.directories.add(dirPath);
            
            // Add parent directories as well
            let currentDir = dirPath;
            while (currentDir.includes('/')) {
                currentDir = currentDir.substring(0, currentDir.lastIndexOf('/'));
                if (currentDir) {
                    this.directories.add(currentDir);
                }
            }
        }
    }

    async deleteFile(filePath: string): Promise<void> {
        this.files.delete(filePath);
    }

    async deleteDir(dirPath: string): Promise<void> {
        // Remove the directory
        this.directories.delete(dirPath);
        
        // Remove all files and subdirectories that start with this path
        const pathPrefix = dirPath + '/';
        
        // Remove matching files
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(pathPrefix)) {
                this.files.delete(filePath);
            }
        }
        
        // Remove matching directories
        for (const dir of this.directories) {
            if (dir.startsWith(pathPrefix)) {
                this.directories.delete(dir);
            }
        }
    }

    async fileExists(filePath: string): Promise<boolean> {
        return this.files.has(filePath);
    }

    async dirExists(dirPath: string): Promise<boolean> {
        return this.directories.has(dirPath);
    }

    async listFiles(prefix: string, limit: number, next?: string): Promise<IListResult> {
        const names: string[] = [];
        let nextMarker: string | undefined = undefined;
        
        const keys = Array.from(this.files.keys())
            .filter(key => key.startsWith(prefix))
            .sort();
        
        const startIndex = next ? keys.indexOf(next) + 1 : 0;
        const endIndex = Math.min(startIndex + limit, keys.length);
        
        for (let i = startIndex; i < endIndex; i++) {
            const relativePath = keys[i].substring(prefix.length);
            names.push(relativePath.startsWith('/') ? relativePath.substring(1) : relativePath);
        }
        
        if (endIndex < keys.length) {
            nextMarker = keys[endIndex];
        }
        
        return { names, next: nextMarker };
    }

    async listDirs(prefix: string, limit: number, next?: string): Promise<IListResult> {
        const names: string[] = [];
        let nextMarker: string | undefined = undefined;
        
        const dirs = Array.from(this.directories)
            .filter(dir => {
                // Get the directory at the current level only
                if (!dir.startsWith(prefix)) return false;
                
                const relativePath = dir.substring(prefix.length);
                // Skip the directory itself and only include immediate children
                return relativePath && !relativePath.includes('/', 1);
            })
            .sort();
        
        const startIndex = next ? dirs.indexOf(next) + 1 : 0;
        const endIndex = Math.min(startIndex + limit, dirs.length);
        
        for (let i = startIndex; i < endIndex; i++) {
            // Extract the directory name (without the prefix)
            const relativePath = dirs[i].substring(prefix.length);
            names.push(relativePath.startsWith('/') ? relativePath.substring(1) : relativePath);
        }
        
        if (endIndex < dirs.length) {
            nextMarker = dirs[endIndex];
        }
        
        return { names, next: nextMarker };
    }

    async info(filePath: string): Promise<IFileInfo | undefined> {
        const file = this.files.get(filePath);
        if (!file) {
            return undefined;
        }
        
        return {
            contentType: file.contentType,
            length: file.data.length,
            lastModified: new Date()
        };
    }

    readStream(filePath: string): Readable {
        const file = this.files.get(filePath);
        if (!file) {
            throw new Error(`File not found: ${filePath}`);
        }
        
        const stream = new Readable();
        stream.push(file.data);
        stream.push(null);
        return stream;
    }

    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        return new Promise((resolve, reject) => {
            const chunks: Buffer[] = [];
            
            inputStream.on('data', (chunk) => {
                chunks.push(Buffer.from(chunk));
            });
            
            inputStream.on('end', () => {
                const data = Buffer.concat(chunks);
                this.write(filePath, contentType, data)
                    .then(resolve)
                    .catch(reject);
            });
            
            inputStream.on('error', (err) => {
                reject(err);
            });
        });
    }

    async copyTo(srcPath: string, destPath: string): Promise<void> {
        const file = this.files.get(srcPath);
        if (!file) {
            throw new Error(`Source file not found: ${srcPath}`);
        }
        
        await this.write(destPath, file.contentType, file.data);
    }
}