import * as fs from "fs-extra";
import * as path from "path";
import { IAssetInfo, IListResult, IStorage } from "./storage";
import { Readable } from "stream";
import { fstat } from "fs";

export class FileStorage implements IStorage {

    constructor() {
        fs.ensureDirSync("files/metadata");
        fs.ensureDirSync("files/hash");
        fs.ensureDirSync("files/original");
        fs.ensureDirSync("files/thumb");
        fs.ensureDirSync("files/display");
    }

    //
    // List files in storage.
    //
    async list(type: string, max: number, continuationToken?: string): Promise<IListResult> {
        let files = await fs.readdir(path.join("files", type));
        files = files.filter(file => !file.endsWith(".info"));
        return {
            assetIds: files,
        };        
    }

    //
    // Determines the local file name for an asset.
    //
    getLocalFileName(type: string, assetId: string): string {
        return path.join("files", type, assetId);
    }

    //
    // Determines the local info file for an asset.
    //    
    getInfoFileName(type: string, assetId: string): string {
        return this.getLocalFileName(type, assetId) + `.info`;
    }

    //
    // Returns true if the specified asset exists.
    //
    async exists(type: string, assetId: string): Promise<boolean> {
        return await fs.pathExists(this.getLocalFileName(type, assetId));
    }

    //
    // Gets info about an asset.
    //
    async info(type: string, assetId: string): Promise<IAssetInfo> {
        const info = JSON.parse(await fs.readFile(this.getInfoFileName(type, assetId), "utf8"));
        const stat = await fs.stat(this.getLocalFileName(type, assetId));
        return {
            contentType: info.contentType,
            length: stat.size,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(type: string, assetId: string): Promise<Buffer | undefined> {

        const fileName = this.getLocalFileName(type, assetId);

        if (!await fs.pathExists(fileName)) {
            // Returns undefined if the file doesn't exist.
            return undefined;
        }
        
        return await fs.readFile(fileName);
    }

    //
    // Writes a file to storage.
    //
    async write(type: string, assetId: string, contentType: string, data: Buffer): Promise<void> {
        await fs.ensureDir(`files/${type}`);
        await fs.writeFile(this.getLocalFileName(type, assetId), data);
        await fs.writeFile(this.getInfoFileName(type, assetId), JSON.stringify({
            contentType: contentType,
        }, null, 2));
    }

    //
    // Streams a file from stroage.
    //
    readStream(type: string, assetId: string): Readable {
        return fs.createReadStream(this.getLocalFileName(type, assetId));
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(type: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const infoFileName = this.getInfoFileName(type, assetId);
            fs.ensureDir(path.dirname(infoFileName))
                .then(() => {
                    return fs.writeFile(infoFileName, JSON.stringify({
                        contentType: contentType,
                    }, null, 2))
                    .then(() => {
                        const localFileName = this.getLocalFileName(type, assetId);
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
