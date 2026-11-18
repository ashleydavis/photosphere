//
// What an import run reports back to whoever asked for it.
//
// These live here rather than beside the import task itself because automatic import reads them on
// both sides of the divide: from a worker on the CLI and the desktop, and from the WebView on
// mobile, where the import runs in the embedded engine and the loop that drives it does not.
//

//
// Streamed as an import works, so the interface can show what is happening without waiting for the
// run to end.
//
// One event covers both kinds of import. There used to be a second one that only an automatic
// import sent, carrying the same counts plus how far through the photo library it was.
//
export interface IImportProgressEvent {
    // Discriminator matched by onTaskMessage("import-progress").
    type: "import-progress";

    // How many items the run has dealt with, whether it imported them or recognised them as already
    // imported.
    seen: number;

    // How many items were added to the database.
    imported: number;

    // How many items were already in the database: the ones recognised before the file was even
    // opened, as well as the ones the hashing recognised.
    skipped: number;

    // How many of those were recognised before the file was opened at all, which is the part that
    // costs nothing: opening an item on a mobile copies the whole photo out of the library and then
    // hashes it, so an item answered here is never copied and never hashed. Reported apart from
    // `skipped` because the two say very different things about what a pass just spent.
    skippedBeforeOpening: number;

    // How many items could not be imported.
    failed: number;

    // The item the run is working on, for the interface to name.
    currentItem: string | undefined;
}

