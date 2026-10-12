# vendor-library.sh

A library of shell functions, sourced by the `update-*.sh` scripts that take a library's upstream source into `vendor/`. It is not run on its own.

## vendor_library

`vendor_library <repo-root> <name> <url> <version> [<excluded-path>...]`

- Downloads the tarball at `<url>` into `tmp/vendor-<name>/` and unpacks it into `vendor/<name>` with the top directory stripped.
- Each `<excluded-path>` is left out of the unpacking. They are matched against the tarball's own member names (after the top directory is stripped), so they drop whole directories that no build needs (documentation, tests, other language bindings). Nothing is edited or patched.
- Writes `vendor/<name>/VENDORED_VERSION`: the version, then the url it came from.
- When `vendor/<name>` already holds a copy, it is moved to `vendor/<name>.previous` and not deleted. Compare it with the new copy, then delete it yourself. The function refuses to run while a `.previous` or `.next` directory is still there.
