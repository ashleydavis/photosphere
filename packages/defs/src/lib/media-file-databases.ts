//
// Defines a media file database.
//
export interface IMediaFileDatabase {
    //
    // The database id.
    //
    id: string;

    //
    // The set name.
    //
    name: string;
}

//
// Defines a collection of databases.
//
export interface IMediaFileDatabases {
    //
    // The default database.
    //
    defaultDb?: string;

    //
    // The available set of databases.
    //
    dbs: IMediaFileDatabase[];
}