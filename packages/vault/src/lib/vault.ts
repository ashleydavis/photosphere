
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
    // The vault package places no restrictions on this value.
    //
    type: string;

    //
    // The secret value, stored as a plain string.
    // Callers are responsible for serialising structured values (e.g. JSON).
    //
    value: string;
}

//
// Interface for a vault that can store, retrieve, list, and delete secrets.
// Implementations may persist secrets in a local keyring, a password manager,
// an encrypted file, or any other backend.
//
export interface IVault {
    //
    // Retrieves a secret by name.
    // Returns undefined if the secret does not exist.
    //
    get(name: string): Promise<ISecret | undefined>;

    //
    // Creates or overwrites a secret.
    //
    set(secret: ISecret): Promise<void>;

    //
    // Returns all secrets stored in the vault.
    //
    list(): Promise<ISecret[]>;

    //
    // Deletes a secret by name.
    // Does nothing if the secret does not exist.
    //
    delete(name: string): Promise<void>;

    //
    // Checks that all required external tools or dependencies are present.
    // Returns ok=true when everything is available, or ok=false with a
    // human-readable message describing what is missing and how to fix it.
    //
    checkPrereqs(): Promise<IPrereqCheckResult>;
}

//
// Result returned by IVault.checkPrereqs().
//
export interface IPrereqCheckResult {
    //
    // True when all prerequisites are satisfied.
    //
    ok: boolean;

    //
    // Human-readable error message when ok is false, undefined otherwise.
    //
    message: string | undefined;
}
