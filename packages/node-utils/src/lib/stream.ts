import fs from "fs";

//
// Writes a stream to a file.
//
export async function writeStreamToFile(stream: NodeJS.ReadableStream, filePath: string): Promise<void> {
    return new Promise((resolve, reject) => {
        const writeStream = fs.createWriteStream(filePath);
        stream.pipe(writeStream);
        writeStream.on('finish', resolve);
        writeStream.on('error', reject);
    });
}
