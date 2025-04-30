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
// Defines a collection of sets.
//
export interface ISets {
    //
    // The default set.
    //
    defaultSet?: string;

    //
    // The user's sets of assets.
    //
    sets: ISet[];
}