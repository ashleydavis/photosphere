# How it works

Internals of `what-changed`: what runs when, what state is kept, and how one invocation becomes a decision about which scripts to run. For the config file's syntax and the everyday commands, see the [README](../README.md).

## High-level flow

```
    bun what-changed/src/cli.ts [names] [--force] [--plan]
                    │
                    ▼
        parseCliArgs (lib/cli-args.ts)
        flags, target names, config path
                    │
                    ▼
        loadGateConfig (lib/config.ts)
        parse and validate what-changed.json
        rootDir = the config file's directory
                    │
                    ▼
        reject any requested name that is
        not a target in the config
                    │
                    ▼
        loadCache (lib/cache-store.ts)
        .cache/what-changed/file-hashes.json
        .cache/what-changed/target-hashes.json
        (anything unreadable becomes empty)
                    │
                    ▼
        listRepoFiles (lib/list-files.ts)
        git ls-files -z --cached --others --exclude-standard
        then filterIgnoredFiles drops ignoreExtensions
                    │
                    ▼
        hashFiles (lib/file-hash.ts)
        SHA-256 per file, skipped when the
        cached mtime and size both still match
                    │
                    ▼
        save file-hashes.json immediately
        (an optimisation, saved whatever
         the tests go on to do)
                    │
                    ▼
        buildTree (lib/merkle.ts)
        directory hash tree over every file
                    │
                    ▼
        planTargets (lib/plan.ts)
        one TargetPlan per considered target:
        forced / never-passed / changed /
        unchanged / wrong-platform
                    │
                    ▼
        reportPlans (lib/gate.ts)
        one line per target, naming the
        changed paths
                    │
        ┌───────────┴───────────┐
        │                       │
     --plan                 anything to run?
     return 0            no ──► say so, return 0
                             │ yes
                             ▼
        runCommand (lib/run-command.ts)
        [...runnerCommand, ...names to run]
        stdio inherited, run from rootDir
                             │
                ┌────────────┴────────────┐
             exit 0                   non-zero
                │                         │
                ▼                         ▼
    merge plan-time pathHashes      record nothing,
    into target-hashes.json,        return that code
    return 0
```

## The file list

Enumeration goes through `git ls-files -z --cached --others --exclude-standard`, run in `rootDir`. That is tracked files plus untracked files that no ignore rule matches.

Using git rather than a directory walk buys exact `.gitignore` semantics for free, including nested `.gitignore` files, negations, and the global excludes file. Writing an equivalent matcher would be more code and would drift from what git actually ignores.

The cost is a hard requirement: the project must be a git repository and `git` must be on `PATH`. When it is not, the run fails loudly rather than falling back to a directory walk, because a silently smaller file list means a silently skipped suite.

The `-z` form is what makes paths with spaces, quotes or newlines survive intact. `parseGitFileList` splits on NUL only, then sorts and de-duplicates.

`ignoreExtensions` is applied to that list before anything else happens. Filtering at enumeration rather than at decision time is what makes the rule total: an ignored file cannot reach the hash tree, so it cannot influence any target, and it cannot appear in the changed-file listing either. The recorded baseline is filtered by the same rule when it is read back, so adding an extension to the list does not report every already-recorded file of that type as a deletion.

`git ls-files` returns paths relative to the directory it runs in, so everything downstream is relative to `rootDir`, which is the config file's directory. Put the config at the repository root unless you deliberately want only a subtree watched.

## Hashing

`hashFile` stats the file first. If `file-hashes.json` holds an entry whose `mtimeMs` and `size` both match, the recorded hash is returned and the file is never opened. Otherwise the file is read and a SHA-256 hex digest is computed and written back into the cache.

Both fields have to match. Size alone misses a same-length edit; mtime alone misses a filesystem with coarse timestamps and misses a restore that resets the timestamp.

A file that has vanished between being listed and being hashed returns the literal `<missing>` rather than an error, and its cache entry is left alone. The listing and the hashing are two separate passes over a live working tree, so this race is normal, and a deleted file has to hash to something stable so the directory above it changes when the file goes away. Any stat or read error that is not `ENOENT` propagates: that is a real problem with the path list, not a race.

Hashing is sequential. In the steady state it is one `stat` per file and nothing else, so there is no throughput to win and no file-descriptor ceiling to reason about. Measured on a monorepo of 2189 tracked and untracked files: about 0.09s warm and 0.20s cold, against a process startup floor of about 0.02s.

`pruneFileHashes` drops entries for files that are no longer in the list, so a long-lived checkout does not accumulate an entry for every file it has ever had.

## The hash tree

`buildTree` turns the flat map of path to content hash into a tree of `TreeNode`. A file node carries its content hash and no children. A directory node's hash is the SHA-256 over its entries sorted by name, each contributing `name`, a NUL byte, the child hash, and a newline.

Three properties come out of that framing, and each one matters:

- **Order independence.** Sorting by name before hashing means the tree does not depend on the order git listed the files in.
- **No boundary collisions.** The NUL and the newline stop a name and a hash running together, so a directory holding `ab` with hash `c` cannot hash the same as one holding `a` with hash `bc`. Without that, some renames would leave the directory hash unchanged.
- **Cheap prefix queries.** `hashForPath` walks the segments and returns that node's hash, so "has anything under `src/parser` changed" is one lookup rather than a scan, and the changed path can be named back to the user.

A path that is not in the tree returns the literal `<missing>`. That is deliberate: a target may watch a directory that does not exist yet, and it has to hash to something stable so that creating the first file under it counts as a change rather than being invisible.

An empty relative path returns the root hash, which is the hash of the whole working set.

## The decision

`planTargets` filters to the requested names (all of them when none were given) and calls `planTarget` for each. `planTarget` is pure: it takes the config, the tree, the previously recorded hashes, the platform string and the force flag, and returns a `TargetPlan`. No disk, no clock, no `process`. That is what makes the whole rule testable.

Every plan carries `pathHashes`, the freshly computed hash of each watched path, **whether or not the target is going to run**. The caller therefore never has to recompute, and a target that was skipped this time still has a hash ready if a later run needs it.

The order of the checks is the rule:

1. **Platform.** If `platforms` is non-empty and does not include the host, the answer is `wrong-platform` and the target does not run. This is checked first, so it beats `--force`: a suite whose toolchain is not on this machine cannot be made to run by asking harder.
2. **Force.** `--force` gives `forced` and the target runs.
3. **Never passed.** No recorded entry gives `never-passed` and the target runs. A cache that was deleted, corrupted, or has never existed lands here, which is why a damaged cache costs a slow run rather than a wrong one.
4. **Changed.** Each watched path (the target's own `paths` merged with `alwaysPaths`, de-duplicated and sorted) is compared against its recorded hash. Any difference gives `changed`, and the differing paths are listed. A watched path absent from the recorded entry counts as changed, so adding a path to a target's config makes that target run next time.
5. **Otherwise** the answer is `unchanged` and the target does not run.

## Recording

Nothing is recorded unless the runner exits 0, and then every target that ran is recorded at once.

**Why all-or-nothing.** A runner that stops at the first failure leaves the rest of its scripts unrun, so a script that had not finished has no result, and one that did finish cannot be told apart from one that was cancelled. There is no trustworthy per-script outcome to record. Recording nothing means a target that passed inside a failing run will run again next time: that wastes some time and cannot produce a wrong answer, which is the right way round.

**Why plan-time hashes.** The recorded hashes are the ones computed before the runner started, not a fresh read afterwards. They describe the tree that was actually tested. Reading the tree again after the run would fold in any edit made while the tests were running and mark it as tested, which is exactly the mistake that would let a broken change through.

**Why the file hashes are saved separately.** `file-hashes.json` is written immediately after hashing, before the runner is even started, and is saved whatever the outcome. It records only what a file's content hashes to, which is true regardless of whether any test passed. Losing it would cost a slow run and nothing else.

Both files are written to a `.tmp` sibling and renamed over the target, so a crash part way through a write cannot leave a half-written file for the next run to choke on.

## Reading the cache back

`loadCache` is deliberate about being unable to fail. A missing directory, a missing file, JSON that will not parse, or JSON that parses to an array, a number or `null` all produce an empty object.

The reasoning is asymmetric. A damaged cache that is treated as empty causes a full run: slow, correct, self-healing. A damaged cache that raises causes a blocked commit for a reason the user cannot act on. The first failure mode is strictly better, so it is the one that was chosen.

Note the contrast with the config file, where the opposite rule applies: a malformed config is a hard error naming the offending field. A config that quietly half-applied would mean a suite that quietly stopped running, which is silent and permanent, where a bad cache is loud and temporary.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Nothing needed to run, or `--plan` was given, or the runner ran and exited 0 |
| the runner's own code | The runner ran and failed. Passed through unchanged so the caller sees what the runner saw. |
| 128 + signal | The runner was killed by a signal, so a Ctrl-C is never mistaken for success |
| 1 | The tool itself failed: unreadable or invalid config, unknown target name, unknown option, git missing or failing |

## What it cannot see

The tool only knows about the working tree. Anything outside it is invisible:

- A different emulator, a new SDK version, a changed environment variable, a rotated credential.
- A dependency installed into `node_modules`, which is gitignored and therefore never hashed. `bun.lock` is in `alwaysPaths` for exactly this reason: the lockfile is the tracked proxy for the installed tree.
- Time. There is no cooldown and no expiry. A suite that passed a month ago against an identical tree is still considered passed.

`--force` is the answer to all of these, and it is why the ungated runner stays reachable under its own script name.

## Module map

| File | Holds |
| --- | --- |
| `src/cli.ts` | The entry point, and nothing else. Six lines wiring the real process to `runGate`. Nothing may import it: it runs on load. |
| `src/lib/gate.ts` | `runGate`, the whole flow. Takes the working directory and the platform as arguments rather than reading `process`, so it can be driven against a throwaway repository. |
| `src/lib/cli-args.ts` | Argument parsing and the usage text. |
| `src/lib/config.ts` | Parsing and validating `what-changed.json`. |
| `src/lib/list-files.ts` | The git enumeration and its NUL parser. |
| `src/lib/file-hash.ts` | Per-file hashing and the mtime/size cache. |
| `src/lib/merkle.ts` | The directory hash tree. |
| `src/lib/plan.ts` | The pure decision function. |
| `src/lib/cache-store.ts` | Reading and writing the two cache files. |
| `src/lib/run-command.ts` | Spawning the runner and turning its outcome into an exit code. |
