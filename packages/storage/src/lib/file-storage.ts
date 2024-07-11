import * as fs from "fs-extra";
import { join, dirname } from "path";
import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "./storage";

export class FileStorage implements IStorage {

    //
    // List files in storage.
    //
    async list(path: string, max: number, next?: string): Promise<IListResult> {
        const dir = join("files", path);
        if (!await fs.pathExists(dir)) {
            return {
                fileNames: [],
                next: undefined,
            };
        }

        let fileNames = await fs.readdir(dir);
        fileNames = fileNames.filter(file => !file.endsWith(".info"));
        return {
            fileNames,
            next: undefined,
        };        
    }

    //
    // Determines the local file name for a file.
    //
    getLocalFileName(path: string, fileName: string): string {
        return join("files", path, fileName);
    }

    //
    // Determines the local info file for a file.
    //    
    getInfoFileName(path: string, fileName: string): string {
        return this.getLocalFileName(path, fileName) + `.info`;
    }

    //
    // Returns true if the specified file exists.
    //
    async exists(path: string, fileName: string): Promise<boolean> {
        return await fs.pathExists(this.getLocalFileName(path, fileName));
    }

    //
    // Gets info about a file.
    //
    async info(path: string, fileName: string): Promise<IFileInfo | undefined> {
        const filePath = this.getInfoFileName(path, fileName)
        if (!await fs.pathExists(filePath)) {
            return undefined;
        }
        const info = JSON.parse(await fs.readFile(filePath, "utf8"));
        const stat = await fs.stat(this.getLocalFileName(path, fileName));
        return {
            contentType: info.contentType,
            length: stat.size,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(path: string, fileName: string): Promise<Buffer | undefined> {
        const filePath = this.getLocalFileName(path, fileName);
        if (!await fs.pathExists(filePath)) {
            // Returns undefined if the file doesn't exist.
            return undefined;
        }
        
        return await fs.readFile(filePath);
    }

    //
    // Writes a file to storage.
    //
    async write(path: string, fileName: string, contentType: string, data: Buffer): Promise<void> {
        await fs.ensureDir(join("files", path));
        await fs.writeFile(this.getLocalFileName(path, fileName), data);
        await fs.writeFile(this.getInfoFileName(path, fileName), JSON.stringify({
            contentType: contentType,
        }, null, 2));
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, fileName: string): Readable {
        return fs.createReadStream(this.getLocalFileName(path, fileName));
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, fileName: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const infoFileName = this.getInfoFileName(path, fileName);
            fs.ensureDir(dirname(infoFileName))
                .then(() => {
                    return fs.writeFile(infoFileName, JSON.stringify({
                        contentType: contentType,
                    }, null, 2))
                    .then(() => {
                        const localFileName = this.getLocalFileName(path, fileName);
                        const fileWriteStream = fs.createWriteStream(localFileName);
                        inputStream.pipe(fileWriteStream)
                            .on("error", (err: any) => {
                                reject(err);
                            })
                            .on("finish", () => {
                                resolve();
                            });
                    })

                })
                .catch((err) => {
                    reject(err);
                });
        });
    }

    //
    // Deletes the file from storage.
    //
    async delete(path: string, fileName: string): Promise<void> {
        await fs.unlink(this.getLocalFileName(path, fileName));
        await fs.unlink(this.getInfoFileName(path, fileName));
    }
}
