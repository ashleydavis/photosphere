import * as path from "path";
import { createHash } from "crypto";
import { getCacheDir } from "node-utils";

//
// Where this machine keeps what it has worked out about one database.
//
// Everything under here is local to this machine and belongs to one database: the hash cache today,
// and whatever else later needs to be remembered about a database without being part of it. It is
// never uploaded, never synced and never replicated, and losing it costs only the time to work the
// contents out again.
//
// It is deliberately not inside the database. A database can be an S3 bucket with no local directory
// at all, and a database on shared storage is opened by several machines at once: a file kept there
// would be read and written by all of them with no lock and no merge, so the last writer would erase
// what the others had learnt. What each machine knows is also useless to the others, because it is
// keyed by that machine's own file paths and that device's own photo library ids.
//

//
// The directory this machine keeps its own record of one database in.
//
// The database path is hashed rather than used directly: it can be a Windows path, a URL-ish
// "s3:bucket:/path", or anything else the storage layer accepts, none of which is safe to paste into
// a directory name. The hash is stable for a given path, which is all that is needed, and the
// commands that report on these directories print the whole path so nobody has to decode it.
//
export function getDatabaseCacheDir(databasePath: string): string {
    const databaseKey = createHash("sha256").update(databasePath).digest("hex").slice(0, 16);
    return path.join(getCacheDir(), databaseKey);
}
