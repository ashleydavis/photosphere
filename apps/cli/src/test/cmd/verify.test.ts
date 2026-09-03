import { verifyFoundProblems } from "../../cmd/verify";
import type { IVerifyResult, IDatabaseFileVerifyResult } from "node-api";

//
// A verification that found nothing wrong.
//
function cleanResult(): IVerifyResult {
    return {
        totalImports: 0,
        totalFiles: 6758,
        totalSize: 9_000_000_000,
        numUnmodified: 6758,
        numFailures: 0,
        modified: [],
        new: [],
        removed: [],
        filesProcessed: 6758,
        nodesProcessed: 13515,
        recordMismatches: [],
    };
}

//
// A reading of the database's own files that found nothing wrong.
//
function cleanDatabaseFiles(): IDatabaseFileVerifyResult {
    return {
        totalFiles: 208,
        totalSize: 21_000_000,
        validFiles: 208,
        invalidFiles: [],
        errors: [],
    };
}

describe("verifyFoundProblems", () => {

    test("a database with nothing wrong has no problems", () => {
        expect(verifyFoundProblems(cleanResult(), cleanDatabaseFiles())).toBe(false);
    });

    test("a database whose files were never read has no problems of its own", () => {
        expect(verifyFoundProblems(cleanResult(), undefined)).toBe(false);
    });

    //
    // The one this was written for. Every file was present and hashed correctly, and 180 assets had
    // no database record: the sync pushes files first and the records that describe them after, so
    // stopping it part way leaves exactly this. The command printed it and exited 0.
    //
    test("an asset whose record is missing is a problem", () => {
        const result = cleanResult();
        result.recordMismatches = [ "asset/f1e7336b-6bbc-4a19-aacd-c1b6887bf542" ];
        expect(verifyFoundProblems(result, cleanDatabaseFiles())).toBe(true);
    });

    test("a file whose bytes changed is a problem", () => {
        const result = cleanResult();
        result.modified = [ "asset/one" ];
        expect(verifyFoundProblems(result, cleanDatabaseFiles())).toBe(true);
    });

    test("a file that could not be read is a problem", () => {
        const result = cleanResult();
        result.numFailures = 1;
        expect(verifyFoundProblems(result, cleanDatabaseFiles())).toBe(true);
    });

    test("a file the tree does not know about is a problem", () => {
        const result = cleanResult();
        result.new = [ "asset/two" ];
        expect(verifyFoundProblems(result, cleanDatabaseFiles())).toBe(true);
    });

    test("a file the tree expects and cannot find is a problem", () => {
        const result = cleanResult();
        result.removed = [ "asset/three" ];
        expect(verifyFoundProblems(result, cleanDatabaseFiles())).toBe(true);
    });

    test("a corrupt database file is a problem", () => {
        const databaseFiles = cleanDatabaseFiles();
        databaseFiles.invalidFiles = [ ".db/files.dat" ];
        expect(verifyFoundProblems(cleanResult(), databaseFiles)).toBe(true);
    });
});
