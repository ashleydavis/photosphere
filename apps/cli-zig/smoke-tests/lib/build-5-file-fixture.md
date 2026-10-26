# build-5-file-fixture.sh

Builds the five-file database once for a whole Zig CLI smoke run, so the tests that need one copy it instead of each building an identical copy. The runner (`smoke-tests.sh`) runs it before the tests start; it is not run by hand.

It takes no arguments. It runs from `apps/cli-zig` with `TEST_TMP_DIR` set to a directory of the run's own:

```
TEST_TMP_DIR=<dir> bash smoke-tests/lib/build-5-file-fixture.sh
```

It leaves the database at `<dir>/db` and the UUID counter at `<dir>/photosphere-test-uuid-counter`, the pair `create_db_with_5_files` in `common.sh` copies, and checks the database with `psi verify` after each step.
