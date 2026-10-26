# functions.sh

The test functions of the core Zig CLI smoke tests (creating a database, adding each kind of file, replicating, verifying and the rest). A test under `smoke-tests/<number>-<name>/` sources `common.sh` and this file, then calls the function it is named for with its test number. It takes no arguments, runs nothing when sourced and sets no traps; the test does that.

Every function that writes a database checks it afterwards with `verify_database` from `common.sh`.
