import { CloudStorage } from '../lib/cloud-storage';

//
// The error S3 returns from a conditional write when the lock object already exists.
//
function preconditionFailed(): any {
    const error: any = new Error('At least one of the pre-conditions you specified did not hold');
    error.name = 'PreconditionFailed';
    error.$metadata = { httpStatusCode: 412 };
    return error;
}

//
// The error S3 returns from a read when the object is not there.
//
function noSuchKey(): any {
    const error: any = new Error('The specified key does not exist.');
    error.name = 'NoSuchKey';
    return error;
}

//
// A lock object body as S3 hands it back, naming its owner and when it was taken.
//
function lockBody(owner: string, timestamp: number): any {
    return {
        Body: {
            transformToString: async () => JSON.stringify({
                owner,
                acquiredAt: new Date(timestamp).toISOString(),
                timestamp,
            }),
        },
    };
}

//
// A CloudStorage whose S3 client is replaced by one that answers from the given handler and records
// the commands it was sent, so a test can drive acquireWriteLock through an exact server response.
//
function createStorage(handler: (commandName: string) => Promise<any>): { storage: CloudStorage, sent: string[] } {
    const sent: string[] = [];
    const storage = new CloudStorage('s3:');
    (storage as any).s3 = {
        async send(command: any): Promise<any> {
            const commandName = command.constructor.name;
            sent.push(commandName);
            return handler(commandName);
        },
    };
    return { storage, sent };
}

describe('CloudStorage write lock', () => {

    const lockPath = 'test-bucket/db/.db/write.lock';

    test('refuses the lock while another owner holds a live one', async () => {
        const { storage, sent } = createStorage(async commandName => {
            if (commandName === 'PutObjectCommand') {
                throw preconditionFailed();
            }
            return lockBody('owner-a', Date.now());
        });

        expect(await storage.acquireWriteLock(lockPath, 'owner-b')).toBe(false);
        expect(sent).not.toContain('DeleteObjectCommand');
    });

    //
    // The failure this pins: the lock is there, because the conditional write was refused, but
    // reading it back returns nothing because the read raced its owner. Treating that as a corrupt
    // lock and breaking it put three processes in the critical section at once.
    //
    test('refuses the lock when it is there but reads back as absent', async () => {
        const { storage, sent } = createStorage(async commandName => {
            if (commandName === 'PutObjectCommand') {
                throw preconditionFailed();
            }
            throw noSuchKey();
        });

        expect(await storage.acquireWriteLock(lockPath, 'owner-b')).toBe(false);
        expect(sent).not.toContain('DeleteObjectCommand');
    });

    test('still breaks a lock that has aged past the timeout and takes it', async () => {
        let puts = 0;
        const { storage, sent } = createStorage(async commandName => {
            if (commandName === 'PutObjectCommand') {
                puts += 1;
                if (puts === 1) {
                    throw preconditionFailed(); // The stale lock is still there.
                }
                return {}; // The write after the delete takes it.
            }
            if (commandName === 'DeleteObjectCommand') {
                return {};
            }
            return lockBody('owner-a', Date.now() - 60_000);
        });

        expect(await storage.acquireWriteLock(lockPath, 'owner-b')).toBe(true);
        expect(sent).toContain('DeleteObjectCommand');
    });
});
