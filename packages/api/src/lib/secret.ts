//
// A secret as the user interface reads and writes it through the platform's vault.
//

//
// Represents a secret stored in a vault.
// The type field is a caller-defined string that categorises the secret
// (e.g. "password", "api-key", "private-key", "s3-credentials").
//
export interface ISecret {
    //
    // Unique name that identifies the secret within the vault.
    //
    name: string;

    //
    // Caller-defined category string for the secret.
    // The vault places no restrictions on this value.
    //
    type: string;

    //
    // The secret value, stored as a plain string.
    // Callers are responsible for serialising structured values (e.g. JSON).
    //
    value: string;
}
