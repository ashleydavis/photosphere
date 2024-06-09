//
// Maps hashes to assets.
//
export interface IHashRecord {
    //
    // The hash.
    //
    _id: string;
    
    //
    // Asset ids that map to this hash.
    //
    assetIds: string[];
}