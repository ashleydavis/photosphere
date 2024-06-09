//
// Defines a user's collection.
//
export interface ICollections {
    //
    // The default collection to upload to the user.
    //
    upload: string;

    //
    // The default collection to view for the user.
    //
    default: string;

    //
    // The collections the user has access to.
    //
    access: string[];
}

//
// Defines a user.
//
export interface IUser {
    //
    // The user id.
    //
    _id: string;

    //
    // Metadata for the user's collections.
    //
    collections: ICollections;
}