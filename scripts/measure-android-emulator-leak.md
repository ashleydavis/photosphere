# Measuring the Android emulator memory leak

`measure-android-emulator-leak.sh` runs the Android smoke tests over and over and reports how much memory the emulators are holding after each run. It exists to answer one question: does a test lose memory it never gives back?

That question matters because `bun run find-flakey-tests -- --script test:and --target 100` cannot finish while a leak exists. Each pool emulator has an 8G allowance. A test that costs a few hundred megabytes every run fills that allowance in a couple of dozen runs, and the emulators are then throttled and killed long before a hundred consecutive green runs are done.

## Before you start

The pool has to be up already. The script never starts, stops or restarts an emulator, and it refuses to run when the pool is down. That is deliberate: a restarted emulator starts from zero, which erases the growth being measured.

```
bun run emu:and:pool:up
```

## Using it

```
bun run measure-android-leak                    # the default: 2-create-database, 20 runs
bun run measure-android-leak -- --all           # every test in turn, a verdict for each
bun run measure-android-leak -- --full          # the whole suite each run
bun run measure-android-leak -- --runs 40       # more runs, for a firmer verdict
bun run measure-android-leak -- --detail        # also report what is growing inside each emulator
bun run measure-android-leak -- --to-the-end    # keep going until an emulator is killed
```

### Measuring any single test

`--test` takes the same filter the suite itself takes: a test number, part of a name, or the full directory name. All three of these measure `44-receive-database-cancel`:

```
bun run measure-android-leak -- --test 44
bun run measure-android-leak -- --test receive-database-cancel
bun run measure-android-leak -- --test 44-receive-database-cancel
```

Combine it with `--runs` for a longer session on one test:

```
bun run measure-android-leak -- --test 32 --runs 40
```

A filter that matches nothing fails immediately and prints the list of tests, so that is also how to see what is available:

```
bun run measure-android-leak -- --test ?
```

Ctrl-C is safe at any point. The script reports on the runs that finished, and the suite cleans up after itself (it traps the signal, and its device lock is a `flock` that the kernel releases whatever happens to the process). Do not use `kill -9`: that cannot be caught, and it leaves the app running on the emulator.

## Reading a single-test run

```
         pool    used of 40.0G               added
start    16.9G   [########............] 42%  baseline
run 1    17.0G   [########............] 42%  +28M       .                     warm-up, not counted
run 2    17.2G   [########............] 43%  +180M      #                     126 runs left
```

- **pool** is what the emulators are holding between them, against what they are allowed. One block is a couple of gigabytes, so this bar moves slowly. It answers how much room is left, not whether memory is still being lost.
- **added** is what that one run cost, as a number and as blocks of 100M each. This is the actual measurement. A run smaller than one block shows `.`, and one that added nothing shows `-`.
- **runs left** is how many more runs before the pool is full, at the average rate so far.

Run 1 is warm-up. It installs the app on every emulator, launches it for the first time and brings up a WebView, none of which any later run repeats. It is always much the largest, it proves nothing, and it is excluded from every average and from the verdict.

The session ends with one of three verdicts:

- **LEAK** means growth did not fade. Memory is being lost every run and never returned.
- **NOT A LEAK, STILL SETTLING** means growth more than halved across the session. That is start-up cost working its way out. Run it again with more runs to confirm it reaches zero.
- **NO LEAK** means the measured runs stayed within the noise between two readings of the same idle emulator.

## Finding out what is leaking

The total says a leak exists. `--detail` says what kind it is, which is what decides where to look.

```
bun run measure-android-leak -- --detail
bun run measure-android-leak -- --test 2 --detail --to-the-end
```

Under each run it adds a line per emulator, and at the end a breakdown:

```
run 12   23.9G   [############........] 59%  +1902M     ####################> 8 runs left
         psphere-pool-0        4.9G  heap    3.1G  threads   62  fds   310     +402M
         psphere-pool-1        4.7G  heap    2.9G  threads   61  fds   305     +380M

  emulator             memory/run     heap/run    threads    files
  psphere-pool-0            +180M       +176M         +0       +2
  psphere-pool-1            +178M       +174M         +1       +0
```

How to use it:

- **Memory climbing while threads and files stay flat** is memory allocated and never freed.
- **Threads or files climbing with it** is handles never closed, which is a different bug in a different place.
- **Heap tracking memory** means the growth is in the emulator process itself, not the Android guest. The guest's RAM is a fixed 2048M and cannot grow.
- **Only some emulators growing** means the leak follows the work, since the suite spreads tests over whichever devices are free. **All of them growing** means it is something ambient and the test is not the cause.
- **`throttled N times`** appears when the kernel has started holding an emulator back for being over its allowance. Once that starts, the session is measuring the state of the pool rather than the test.

`--detail` reads `/proc` and the control group after every run. It costs a moment per run and nothing else.

## Running it to the end

A twenty run session tells you whether a test leaks. It does not tell you how much that costs, and the cost is the whole point: the goal is a hundred consecutive green runs, so what matters is how many runs the pool survives.

```
bun run measure-android-leak -- --to-the-end
bun run measure-android-leak -- --test 32 --to-the-end
```

This ignores the run count and keeps going until an emulator is actually killed, up to a cap of 500 runs. Expect it to take hours. Ctrl-C is safe at any point and still prints the verdict for the runs that finished.

You will see the `runs left` column count down as the pool fills, then runs start failing as the emulators are throttled, and finally:

```
psphere-pool-2 stopped answering during run 31. It has been killed or has crashed.
This is the leak reaching its end: an emulator that fills its allowance is throttled
and then killed. 4 of 5 emulators are left.
```

It stops there rather than carrying on. Once an emulator dies the pool is a different size, the survivors absorb its share of the work, and the total falls by several gigabytes for a reason that has nothing to do with the test, so nothing measured past that point is comparable with what came before.

**The run number in that message is the answer.** If an emulator dies at run 31, then `find-flakey-tests` cannot reach a streak of 100, and by how much. Restart the pool before measuring again, because the surviving emulators are already part way to the same end:

```
bun run emu:and:pool:restart
```

## Reading a sweep

`--all` measures every test in turn and prints one line each, then a worst-first table.

```
  2-create-database                     +180M   LEAK
  44-receive-database-cancel             +70M   settling
  1-load-fixture                         +12M   no leak
```

A sweep stops when the pool passes 85% full and tells you how to carry on. Past that point the emulators are throttled and reclaiming under pressure, so what a test appears to cost says more about the state of the pool than about the test. Restart the pool yourself, then resume:

```
bun run emu:and:pool:restart
bun run measure-android-leak -- --all --resume-from <the test it named>
```

## How it works

After every run, with the pool idle, it reads each emulator's control group and sums `anon` from `memory.stat` with `memory.swap.current`. It compares that total against the previous reading. The per-run readings go to `tmp/android-emulator-leak.csv` and the suite's own output to `tmp/android-emulator-leak-runs.log`.

The verdict is not the total growth. Memory that grows and then stops is a cache filling up and is harmless; memory still being added at the end of a session is what runs the pool out. A single average over the whole session cannot tell those apart and calls both a leak. So the runs after warm-up are split down the middle and the second half is compared against the first. Growth that has halved or better is on its way out. Growth that has held is a leak.

### Why anonymous memory plus swap

Resident set size is useless here. The pool emulators are allowed to swap, so RSS drops by hundreds of megabytes when the kernel pages an idle emulator out and climbs again when it is touched. It shows a sawtooth that says nothing about leaking.

`memory.current` is useless too, for the reason set out in `apps/android-frontend/scripts/emulator-pool-monitor.sh`: it counts page cache, cache grows to fill whatever it is allowed, and a healthy emulator therefore sits near 100% of its limit forever.

Anonymous memory cannot be reclaimed, so it is the part that actually runs an emulator out of room. Adding the swapped-out part back means a page moving to swap does not look like memory being freed. That sum is the number that only goes up when something leaks.

The whole control group is read rather than the emulator's main process, because an emulator is a tree of processes and the main one accounts for only part of what it costs.

## What is known so far

The leak is host-side, in the emulator process rather than in the Android guest: the guest's `ram.img` is fixed at 2048M and fully touched. It is not the test harness or the host bridge, since repeated launch and teardown with no test at all produces no growth. `2-create-database` is the only test that has been measured on its own, and it grew the pool. Which of the other tests contribute, and why the whole suite costs far more per run than that one test accounts for, is what `--all` exists to find out.
