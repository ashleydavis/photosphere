import * as fs from "fs-extra";
import * as path from "path";
import { IStorage } from "./storage";
import { Readable, Writable } from "stream";

export class FileStorage implements IStorage {

    //
    // Initialises the storage interface.
    //
    async init(): Promise<void> {
        await fs.ensureDir("uploads");
        await fs.ensureDir("thumbs");
    }

    //
    // Reads an file from stroage.
    //
    read(type: string, assetId: string): Readable {
        const localFileName = path.join(type, assetId);
        return fs.createReadStream(localFileName);
    }

    //
    // Writes an input stream to storage.
    //
    write(type: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const fileWriteStream = fs.createWriteStream(path.join(type, assetId));
            inputStream.pipe(fileWriteStream)
                .on("error", (err: any) => {
                    reject(err);
                })
                .on("finish", () => {
                    resolve();
                });
        });
    }
}
