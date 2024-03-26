import * as fs from "fs-extra";
import * as path from "path";
import { IAssetInfo, IListResult, IStorage } from "./storage";
import { Readable } from "stream";
import { fstat } from "fs";

export class FileStorage implements IStorage {

    //
    // List files in storage.
    //
    async list(accountId: string, type: string, max: number, continuationToken?: string): Promise<IListResult> {
        const dir = path.join("files", accountId, type);
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
    getLocalFileName(accountId: string, type: string, assetId: string): string {
        return path.join("files", accountId, type, assetId);
    }

    //
    // Determines the local info file for an asset.
    //    
    getInfoFileName(accountId: string, type: string, assetId: string): string {
        return this.getLocalFileName(accountId, type, assetId) + `.info`;
    }

    //
    // Returns true if the specified asset exists.
    //
    async exists(accountId: string, type: string, assetId: string): Promise<boolean> {
        return await fs.pathExists(this.getLocalFileName(accountId, type, assetId));
    }

    //
    // Gets info about an asset.
    //
    async info(accountId: string, type: string, assetId: string): Promise<IAssetInfo> {
        const info = JSON.parse(await fs.readFile(this.getInfoFileName(accountId, type, assetId), "utf8"));
        const stat = await fs.stat(this.getLocalFileName(accountId, type, assetId));
        return {
            contentType: info.contentType,
            length: stat.size,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(accountId: string, type: string, assetId: string): Promise<Buffer | undefined> {

        const fileName = this.getLocalFileName(accountId, type, assetId);
        if (!await fs.pathExists(fileName)) {
            // Returns undefined if the file doesn't exist.
            return undefined;
        }
        
        return await fs.readFile(fileName);
    }

    //
    // Writes a file to storage.
    //
    async write(accountId: string, type: string, assetId: string, contentType: string, data: Buffer): Promise<void> {
        await fs.ensureDir(`files/${type}`);
        await fs.writeFile(this.getLocalFileName(accountId, type, assetId), data);
        await fs.writeFile(this.getInfoFileName(accountId, type, assetId), JSON.stringify({
            contentType: contentType,
        }, null, 2));
    }

    //
    // Streams a file from stroage.
    //
    readStream(accountId: string, type: string, assetId: string): Readable {
        return fs.createReadStream(this.getLocalFileName(accountId, type, assetId));
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(accountId: string, type: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const infoFileName = this.getInfoFileName(accountId, type, assetId);
            fs.ensureDir(path.dirname(infoFileName))
                .then(() => {
                    return fs.writeFile(infoFileName, JSON.stringify({
                        contentType: contentType,
                    }, null, 2))
                    .then(() => {
                        const localFileName = this.getLocalFileName(accountId, type, assetId);
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
}
