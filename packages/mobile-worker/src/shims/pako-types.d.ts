//
// Ambient declaration for `pako`, which ships no TypeScript types. The mobile zlib shim only uses
// `pako.gzip` / `pako.ungzip`, so a permissive module declaration is sufficient and avoids adding a
// separate @types dependency.
//
declare module "pako";

//
// Ambient declaration for `create-hash` (browserify createHash). The mobile crypto shim uses it for
// md5/sha256; the package ships no TypeScript types, so a permissive declaration suffices.
//
declare module "create-hash";
