import * as fs from "fs-extra";
import { join, dirname } from "path";
import { IAssetInfo, IListResult, IStorage } from "database";
import { Readable } from "stream";

export class FileStorage implements IStorage {

    //
    // List files in storage.
    //
    async list(path: string, max: number, continuationToken?: string): Promise<IListResult> {
        const dir = join("files", path);
        if (!await fs.pathExists(dir)) {
            return {
                assetIds: [],
            };
        }

        let files = await fs.readdir(dir);
        files = files.filter(file => !file.endsWith(".info"));
        return {
            assetIds: files,
        };        
    }

    //
    // Determines the local file name for an asset.
    //
    getLocalFileName(path: string, assetId: string): string {
        return join("files", path, assetId);
    }

    //
    // Determines the local info file for an asset.
    //    
    getInfoFileName(path: string, assetId: string): string {
        return this.getLocalFileName(path, assetId) + `.info`;
    }

    //
    // Returns true if the specified asset exists.
    //
    async exists(path: string, assetId: string): Promise<boolean> {
        return await fs.pathExists(this.getLocalFileName(path, assetId));
    }

    //
    // Gets info about an asset.
    //
    async info(path: string, assetId: string): Promise<IAssetInfo> {
        const info = JSON.parse(await fs.readFile(this.getInfoFileName(path, assetId), "utf8"));
        const stat = await fs.stat(this.getLocalFileName(path, assetId));
        return {
            contentType: info.contentType,
            length: stat.size,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(path: string, assetId: string): Promise<Buffer | undefined> {

        const fileName = this.getLocalFileName(path, assetId);
        if (!await fs.pathExists(fileName)) {
            // Returns undefined if the file doesn't exist.
            return undefined;
        }
        
        return await fs.readFile(fileName);
    }

    //
    // Writes a file to storage.
    //
    async write(path: string, assetId: string, contentType: string, data: Buffer): Promise<void> {
        await fs.ensureDir(join("files", path));
        await fs.writeFile(this.getLocalFileName(path, assetId), data);
        await fs.writeFile(this.getInfoFileName(path, assetId), JSON.stringify({
            contentType: contentType,
        }, null, 2));
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, assetId: string): Readable {
        return fs.createReadStream(this.getLocalFileName(path, assetId));
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const infoFileName = this.getInfoFileName(path, assetId);
            fs.ensureDir(dirname(infoFileName))
                .then(() => {
                    return fs.writeFile(infoFileName, JSON.stringify({
                        contentType: contentType,
                    }, null, 2))
                    .then(() => {
                        const localFileName = this.getLocalFileName(path, assetId);
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
    async delete(path: string, assetId: string): Promise<void> {
        await fs.unlink(this.getLocalFileName(path, assetId));
        await fs.unlink(this.getInfoFileName(path, assetId));
    }
}
