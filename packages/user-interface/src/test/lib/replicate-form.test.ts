import { applyDestinationTypeChange, emptyReplicateFormState, type IReplicateFormState } from "../../lib/replicate-form";

//
// A form that has been filled in: S3 chosen, credentials picked, a destination typed.
//
function filledS3Form(): IReplicateFormState {
    return {
        storageType: 's3',
        destPath: 's3:photosphere-smoke-test/desktop-replica',
        mode: 'full',
        secrets: { s3Key: 'smoke-test-s3', encryptionKey: undefined, geocodingKey: undefined },
    };
}

describe("replicate form", () => {

    test("an empty form starts on the filesystem with nothing filled in", () => {
        const form = emptyReplicateFormState();
        expect(form.storageType).toBe('filesystem');
        expect(form.destPath).toBe('');
        expect(form.mode).toBe('partial');
        expect(form.secrets).toEqual({ s3Key: undefined, encryptionKey: undefined, geocodingKey: undefined });
    });

    test("changing the destination type to S3 clears the path written for the old type", () => {
        const previous: IReplicateFormState = { ...emptyReplicateFormState(), destPath: '/home/user/replica' };
        const next = applyDestinationTypeChange(previous, 's3');
        expect(next.storageType).toBe('s3');
        expect(next.destPath).toBe('');
    });

    test("changing the destination type back to the filesystem clears the path too", () => {
        const next = applyDestinationTypeChange(filledS3Form(), 'filesystem');
        expect(next.storageType).toBe('filesystem');
        expect(next.destPath).toBe('');
    });

    test("changing the destination type keeps the chosen secrets and mode", () => {
        const next = applyDestinationTypeChange(filledS3Form(), 'filesystem');
        expect(next.secrets).toEqual({ s3Key: 'smoke-test-s3', encryptionKey: undefined, geocodingKey: undefined });
        expect(next.mode).toBe('full');
    });

    test("reporting the type the form already holds leaves the typed path alone", () => {
        const previous = filledS3Form();
        const next = applyDestinationTypeChange(previous, 's3');
        expect(next).toBe(previous);
        expect(next.destPath).toBe('s3:photosphere-smoke-test/desktop-replica');
    });

    test("a null value falls back to the filesystem", () => {
        const next = applyDestinationTypeChange(filledS3Form(), null);
        expect(next.storageType).toBe('filesystem');
        expect(next.destPath).toBe('');
    });

    test("a null value on a form already on the filesystem leaves the typed path alone", () => {
        const previous: IReplicateFormState = { ...emptyReplicateFormState(), destPath: '/home/user/replica' };
        const next = applyDestinationTypeChange(previous, null);
        expect(next).toBe(previous);
        expect(next.destPath).toBe('/home/user/replica');
    });
});
