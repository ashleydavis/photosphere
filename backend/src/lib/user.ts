//
// Defines a user.
//
export interface IUser {
    //
    // The default account to upload to the user.
    //
    uploadAccount: string;

    //
    // The accounts the user has access to.
    //
    accounts: string[];
}