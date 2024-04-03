//
// Defines a user.
//
export interface IUser {
    //
    // The default collection to upload to the user.
    //
    uploadCollection: string;

    //
    // The collection the user has access to.
    //
    collections: string[];
}