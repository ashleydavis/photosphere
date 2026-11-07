//
// The replicate dialog's form state and the rules for changing it. Kept out of the component so the
// rules can be tested directly: the dialog itself is a thin shell around this state.
//

import type { IDatabaseSecretsSelection } from '../components/configure-secrets-modal';

//
// Where a replica is written: an ordinary directory, or a bucket.
//
export type ReplicateStorageType = "filesystem" | "s3";

//
// How much of the source a replica carries: metadata and structure only, or every file.
//
export type ReplicateMode = "partial" | "full";

//
// Form state for the replicate dialog.
//
export interface IReplicateFormState {
    // Selected destination storage type.
    storageType: ReplicateStorageType;

    // Destination database path (filesystem path or s3:bucket/prefix).
    destPath: string;

    // Selected replication mode.
    mode: ReplicateMode;

    // Vault secret references for the destination (S3, encryption, geocoding).
    secrets: IDatabaseSecretsSelection;
}

//
// Returns an empty form state.
//
export function emptyReplicateFormState(): IReplicateFormState {
    return {
        storageType: 'filesystem',
        destPath: '',
        mode: 'partial',
        secrets: { s3Key: undefined, encryptionKey: undefined, geocodingKey: undefined },
    };
}

//
// The form state after the destination-type Select reports the given value.
//
// A path written for one kind of destination means nothing to the other (`s3:bucket/prefix` is not a
// directory), so a real change to the type clears the path. A report of the type the form already
// holds changes nothing and must leave the path alone: Joy's Select calls its onChange again on
// re-renders that it did not cause, and clearing the path on those wipes what the user typed. That is
// not hypothetical. In the desktop smoke test the Select reported "s3" four times over, three of them
// while the user was in the Configure Secrets modal and while the source database finished opening in
// the background, and the destination typed afterwards could be erased by the next one. The Start
// button is disabled without a destination, so the replication then simply never began.
//
export function applyDestinationTypeChange(previous: IReplicateFormState, value: string | null): IReplicateFormState {
    const storageType = (value as ReplicateStorageType) ?? 'filesystem';
    if (storageType === previous.storageType) {
        return previous;
    }

    return {
        ...previous,
        storageType,
        destPath: '',
    };
}
