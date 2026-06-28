//
// `stream/promises` shim for the embedded mobile worker.
//
// FileStorage.writeStream pipes a readable into the createWriteStream writable via `pipeline`. This
// shim implements `pipeline(source, destination)` over the minimal Readable/Writable shims: it pumps
// the source's data chunks into the destination and resolves once the destination has finished
// writing (or rejects on error).
//

//
// A minimal event-emitter-like stream (the shim Readable/Writable both satisfy this).
//
interface IMinimalStream {
    // Registers an event listener.
    on(eventName: string, listener: (...args: any[]) => void): unknown;

    // Writable streams accept chunks.
    write?(chunk: any): boolean;

    // Writable streams are ended once the source completes.
    end?(): void;
}

//
// Pumps a readable source into a writable destination and resolves when writing finishes. Mirrors
// the subset of stream.pipeline the storage write path uses.
//
export async function pipeline(source: IMinimalStream, destination: IMinimalStream): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        source.on("data", (chunk: any) => {
            if (destination.write) {
                destination.write(chunk);
            }
        });
        source.on("end", () => {
            if (destination.end) {
                destination.end();
            }
        });
        source.on("error", reject);
        destination.on("finish", () => resolve());
        destination.on("error", reject);
    });
}

//
// The default export mirrors `import streamPromises from "stream/promises"`.
//
const streamPromises = { pipeline };

export default streamPromises;
