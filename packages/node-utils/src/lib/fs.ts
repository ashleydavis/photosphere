import * as os from 'os';
import * as path from 'path';

//
// Returns the temp directory to use for this process, the system temp directory by default.
//
// PHOTOSPHERE_TMP_DIR overrides it, and names a directory Photosphere may use as it likes: the
// process temp goes in a "tmp" subdirectory of it, so whatever else lives at that path is left
// alone. Point it at a larger disk when the system temp directory is small, at a location with a
// different retention policy, or at a directory of your own so several Photosphere processes on one
// machine do not share scratch space.
//
// That last use is why the smoke tests set it: each test gets a directory of its own and passes it
// down, so the app writes inside the test's directory and no two tests can reach each other's files.
//
export function getProcessTmpDir(): string {
    if (process.env.PHOTOSPHERE_TMP_DIR) {
        return path.resolve(process.env.PHOTOSPHERE_TMP_DIR, 'tmp');
    }
    return os.tmpdir();
}
