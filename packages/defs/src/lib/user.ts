//
// Defines a set of assets.
//
export interface ISet {
    //
    // The set id.
    //
    id: string;

    //
    // The set name.
    //
    name: string;
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
    // The users's default set.
    //
    defaultSet: string;

    //
    // The user's sets of assets.
    //
    sets: ISet[];
}