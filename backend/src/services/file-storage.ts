import * as fs from "fs-extra";
import * as path from "path";
import { AssetType, IStorage } from "./storage";
import { Readable } from "stream";

export class FileStorage implements IStorage {

    //
    // Initialises the storage interface.
    //
    async init(): Promise<void> {
        await fs.ensureDir("files/original");
        await fs.ensureDir("files/thumb");
        await fs.ensureDir("files/display");
    }

    //
    // Reads an file from stroage.
    //
    read(type: AssetType, assetId: string): Readable {
        const localFileName = path.join("files", type, assetId);
        return fs.createReadStream(localFileName);
    }

    //
    // Writes an input stream to storage.
    //
    write(type: AssetType, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            const localFileName = path.join("files", type, assetId);
            const fileWriteStream = fs.createWriteStream(localFileName);
            inputStream.pipe(fileWriteStream)
                .on("error", (err: any) => {
                    reject(err);
                })
                .on("finish", () => {
                    console.log(`Uplaoded ${localFileName}`); //fio:
                    resolve();
                });
        });
    }
}
