# Performance

The whole point of this tool is to be so much cheaper than the tests it gates that nobody thinks about its cost. This documents what it actually costs, how that was measured, and where the remaining headroom is.

Run the benchmarks yourself with `npm run perf` (or `bun run perf`) from the package directory. They exit non-zero if any stage blows its budget, so they work as a regression test and not only as a report.

## Results

Measured on Linux, Bun 1.3.14, files of 512 bytes spread 50 to a directory. Every number is a single measured run, so treat the small values as indicative rather than precise.

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold, reads every file) | 2.5ms | 18.6ms | 92.6ms | 388.1ms |
| hash (warm, stat only) | 0.8ms | 6.4ms | 41.6ms | 163.3ms |
| build hash tree | 0.8ms | 2.0ms | 6.1ms | 26.7ms |
| lookup every watched path | 0.1ms | 0.0ms | 0.1ms | 0.2ms |
| diff files (nothing changed) | 0.1ms | 0.4ms | 1.8ms | 5.1ms |
| diff files (one changed) | 0.1ms | 0.3ms | 1.7ms | 5.8ms |

Per file, which is what shows whether a stage scales linearly:

| Stage | 100 files | 1000 files | 5000 files | 20000 files |
| --- | --- | --- | --- | --- |
| hash (cold) | 25.37us | 18.65us | 18.52us | 19.40us |
| hash (warm) | 7.91us | 6.38us | 8.32us | 8.16us |
| build hash tree | 7.93us | 2.02us | 1.22us | 1.34us |
| lookup every watched path | 0.71us | 0.02us | 0.02us | 0.01us |
| diff files (nothing changed) | 1.03us | 0.37us | 0.35us | 0.25us |
| diff files (one changed) | 1.35us | 0.29us | 0.33us | 0.29us |

Every stage is linear in the file count. Nothing here degrades as a project grows: doubling the files doubles the cost and does no worse.

## What that means end to end

Measured on a real monorepo of 2189 tracked and untracked files, through the actual CLI including process startup:

| | Time |
| --- | --- |
| Process startup floor (the runtime, doing nothing) | 0.02s |
| Full check, warm cache, nothing changed | 0.11s |
| Full check, cold cache (every file read and hashed) | 0.22s |

Against a test suite of about three and a half minutes, a warm check is roughly **0.05%** of the cost of the thing it is deciding about. The cold case, which happens once after the cache is deleted, is still under a quarter of a second.

Roughly a fifth of the warm number is runtime startup that no amount of optimisation inside the tool can remove.

## Why it is as fast as it is

**The warm path never opens a file.** `hashFile` stats the file and compares `mtimeMs` and `size` against the cache. Both matching means the recorded hash is returned without a read. That is the difference between the cold and warm rows above: 19us per file versus 8us, and the 8us is essentially one `stat` syscall.

**The tree is built once and queried many times.** Building it is about 1.3us per file and does not depend on how many targets there are. Answering "did anything under this path change" is then a walk of the path's segments, which is why the lookup row is flat at 0.01us per file no matter how many watched paths a config has. A config with ten targets costs the same as one with two.

**Nothing is recomputed between stages.** The plan carries the hashes it computed, so recording them after a passing run needs no second pass over the tree.

**The comparison itself is trivial.** Diffing 20000 files against the recorded baseline is 5ms, about 0.3us per file, and it costs the same whether nothing changed or something did.

## Why it is not faster

Two deliberate choices leave measurable time on the table.

**Hashing is sequential.** The obvious optimisation is `Promise.all` over the file list. In the steady state each file costs one `stat`, so the win is bounded by how well the kernel overlaps syscalls, and the cost is a concurrency limit to reason about and a file-descriptor ceiling to get wrong. At 0.16s for 20000 files it is not worth it. If a project ever gets big enough that it is, this is the first thing to change.

**The whole tree is hashed, not just what git says changed.** Git already stores a content hash per tracked file in its index, and `git ls-files -s` hands them over in about 1ms with no reads and no stats. Only dirty and untracked files would then need hashing. That would remove most of the warm cost.

It is not done, for two reasons:

- **Correctness.** Git measures change against HEAD, not against "the tree this target last passed on". After a commit the working tree is clean, so a git-status approach sees no changes; switch branch or pull, and it still sees no changes, and would skip everything while the tree underneath had completely changed. Hashing the whole tree closes that hole, and closing it is worth more than the milliseconds.
- **Hash consistency.** Git blob hashes are SHA-1 over `blob <len>\0<content>`; these are plain SHA-256 over the content. The two cannot be mixed, because a file moving between clean and dirty would change hash without changing content and trigger a spurious run. Adopting git's hashes means computing git-style hashes for the dirty and untracked files too, and taking a dependency on git for hashing as well as enumeration.

Measured cost of the shortcut not taken: `git ls-files -s` is 1ms and `git status --porcelain` is 9ms on the 2189-file repository, against roughly 90ms of hashing. So the ceiling on that optimisation is about 80ms on a warm check, on a run that gates three and a half minutes of tests.

## The budget

`perf-tests/run.ts` fails if warm hashing exceeds **0.05ms per file**. Measured values sit between 0.006ms and 0.008ms, so there is roughly a sixfold margin. The budget is set loose on purpose: it is there to catch a change that makes the warm path read files again, which would show up as a jump to the cold numbers, not to police small variations between machines.

## Reproducing

```bash
npm run perf     # or: bun run perf
```

The harness writes throwaway trees under the system temp directory and removes them afterwards. Sizes run 100, 1000, 5000 and 20000 files, and each size measures cold hashing, warm hashing, tree building, watched-path lookup, and the changed-file diff both when nothing changed and when one file did.
