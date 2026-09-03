import { Readable } from 'stream';
import { CloudStorage } from '../lib/cloud-storage';

//
// A CloudStorage whose S3 client is replaced by one that records the commands it was sent and
// answers from the given handler, so a test can see which upload path a body of a given size takes
// without an S3 server anywhere.
//
interface IFakeClient {
    // The storage under test, with its client replaced.
    storage: CloudStorage;

    // The name of each command class the storage sent, in order.
    sent: string[];

    // The input of each command the storage sent, in the same order.
    inputs: any[];
}

function createStorage(handler: (commandName: string) => Promise<any>): IFakeClient {
    const sent: string[] = [];
    const inputs: any[] = [];
    const storage = new CloudStorage('s3:');
    (storage as any).s3 = {
        config: {
            requestHandler: {},
            endpointProvider: () => ({
                url: new URL('http://s3.test'),
            }),
        },
        async send(command: any): Promise<any> {
            sent.push(command.constructor.name);
            inputs.push(command.input);
            return handler(command.constructor.name);
        },
    };
    return {
        storage,
        sent,
        inputs,
    };
}

//
// A body of the given length that nothing in these tests reads.
//
function aBody(): Readable {
    return Readable.from([ Buffer.alloc(0) ]);
}

describe('CloudStorage writeStreamHashed', () => {

    const hash = Buffer.alloc(32, 7);

    //
    // Every file a phone library holds must go up as one request.
    //
    // A multipart upload cannot be handed a file: its uploader reads the stream into a buffer per
    // part, and on a phone bytes reach a buffer only by crossing the host bridge as base64, twice.
    // Measured on a Pixel 6 against MinIO on the same LAN, with the network proven to carry 11.8MB/s
    // from that phone, every five megabyte part took 2.2 to 2.5 seconds to send and about as long
    // again to read in, while whole files under the old ceiling went up in under a second each.
    //
    test('a video sized body goes up as one request carrying the whole object hash', async () => {
        const { storage, sent, inputs } = createStorage(async () => ({}));

        const verifiedByTheStore = await storage.writeStreamHashed('bucket/db/asset/one', 'video/mp4', aBody(), 79 * 1024 * 1024, hash);

        expect(sent).toEqual([ 'PutObjectCommand' ]);
        expect(inputs[0].ChecksumSHA256).toBe(hash.toString('base64'));
        expect(inputs[0].ContentLength).toBe(79 * 1024 * 1024);

        // The server checked the body against that hash, so the caller has nothing left to ask.
        expect(verifiedByTheStore).toBe(true);
    });

    test('a photo sized body goes up as one request too', async () => {
        const { storage, sent } = createStorage(async () => ({}));

        expect(await storage.writeStreamHashed('bucket/db/asset/two', 'image/jpeg', aBody(), 2 * 1024 * 1024, hash)).toBe(true);
        expect(sent).toEqual([ 'PutObjectCommand' ]);
    });

    //
    // A body too large for one request still has a path, because S3 refuses a single PUT over five
    // gigabytes.
    //
    test('a body larger than one request allows goes up in parts', async () => {
        const { storage, inputs } = createStorage(async () => ({}));

        // False says the store did not check the bytes against the hash, which is what the multipart
        // path means: a multipart checksum is a hash of the parts' hashes rather than of the object,
        // so it cannot be compared with the hash the database holds and the caller has to verify.
        expect(await storage.writeStreamHashed('bucket/db/asset/huge', 'video/mp4', aBody(), 3 * 1024 * 1024 * 1024, hash)).toBe(false);

        // No request carried the whole-object hash, because none of them could.
        expect(inputs.every(input => input.ChecksumSHA256 === undefined)).toBe(true);
    });

    //
    // A failed write must say so rather than report a copy that never happened.
    //
    test('a refused write is reported, naming the file', async () => {
        const { storage } = createStorage(async () => {
            throw new Error('Access Denied');
        });

        await expect(storage.writeStreamHashed('bucket/db/asset/three', 'image/jpeg', aBody(), 1024, hash))
            .rejects.toThrow('bucket/db/asset/three');
    });
});
