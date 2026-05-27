# CLI Import Tests

Manual test scripts for importing files via the `psi` CLI.

## Tests

- [add-and-verify.md](add-and-verify.md) - Create a database, import a file, list it, and verify the database
- [add-png.md](add-png.md) - Add a PNG file to a database
- [add-mp4.md](add-mp4.md) - Add an MP4 video file to a database
- [add-same-file-twice.md](add-same-file-twice.md) - Adding the same file twice does not duplicate the asset
- [add-multiple-files.md](add-multiple-files.md) - Add multiple files in a single command
- [add-duplicate-content.md](add-duplicate-content.md) - Two files with identical content dedupe to one asset
- [no-overwrite-existing-database.md](no-overwrite-existing-database.md) - `init` refuses to overwrite an existing database
