import * as fsSync from 'fs';
import * as path from 'path';
import { getProcessTmpDir } from './fs';

//
// The name of the directory that holds every per-test directory. Kept separate from the CLI's own
// "photosphere" directory under the same root so a test tree can never be confused with, or deleted
// by, a product code path such as clearCacheCommand.
//
const TEST_TEMP_ROOT_NAME = 'photosphere-tests';

//
// Characters allowed in the label part of a per-test directory name. Everything else is replaced,
// so a label carrying a path separator, a space or a shell metacharacter cannot steer the directory
// somewhere other than under the test temp root.
//
const UNSAFE_LABEL_CHARACTERS = /[^A-Za-z0-9._-]/g;

//
// Returns the directory that per-test temporary directories are created inside. It sits under the
// process temp root, so pointing the process temp root at a per-test location (which the smoke test
// runners do) moves this with it.
//
export function getTestTempRoot(): string {
    return path.join(getProcessTmpDir(), TEST_TEMP_ROOT_NAME);
}

//
// Creates a temporary directory that belongs to one test and returns its absolute path.
//
// Uniqueness comes from the operating system (mkdtemp), not from a timestamp or a counter: two
// tests starting in the same millisecond is exactly the case a timestamp misses, and that is how
// tests ended up sharing a directory and interfering with each other. The label is included in the
// name so a directory left behind can be traced back to the test that made it.
//
export function createTestTempDir(label: string): string {
    const testTempRoot = getTestTempRoot();
    fsSync.mkdirSync(testTempRoot, { recursive: true });
    const safeLabel = label.replace(UNSAFE_LABEL_CHARACTERS, '-');
    return fsSync.mkdtempSync(path.join(testTempRoot, `${safeLabel}-`));
}
