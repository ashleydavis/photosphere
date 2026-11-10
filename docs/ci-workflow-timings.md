# CI workflow timings

Measured from the most recent complete set of runs: commit `9583dfc` on `zig-2`, pushed 2026-11-10, every workflow green. Every
workflow ran on that push, side by side. Times are wall clock from the run being created to its last job finishing.

## Workflows

| Workflow | Total | Slowest job | Critical path |
| --- | --- | --- | --- |
| Release iOS | 55m | app-smoke-tests 37m | libraries 3m, queue 4m, app-build 6m, zig-unit-tests 4m, app-smoke-tests 37m |
| Release Linux | 35m | app-smoke-tests 28m | libraries 2m, app-build 5m, app-smoke-tests 28m |
| Release macOS x64 | 35m | app-smoke-tests 15m | libraries 4m, queue 5m, app-build 10m, app-smoke-tests 15m |
| Release Android | 31m | app-smoke-tests 21m | libraries 2m, app-build 8m, app-smoke-tests 21m |
| Release macOS arm64 | 28m | app-smoke-tests 9m | libraries 2m, queue 2m, cli-build 5m, app-build 6m, zig-unit-tests 4m, app-smoke-tests 9m |
| Release Windows | 28m | app-smoke-tests 19m | libraries 2m, app-build 6m, app-smoke-tests 19m |
| CI (Linux) | 12m | zig-unit-tests-linux 8m | libraries 0.5m, cli-build-linux 2.5m, zig-unit-tests-linux 8m |

## Jobs

Job duration, then the steps of 20 seconds or more.

### Release iOS (55m)

- app-smoke-tests 37m: smoke tests 34.5m (68 scenarios, one at a time on one simulator, about 28s each), toolchain check 0.7m, media tools 0.7m
- app-build 6m: build for the simulator 4m
- zig-unit-tests 3.7m: tests 1.8m. The same command on the same runner as the macOS arm64 workflow's zig-unit-tests
- typescript-unit-tests 1.5m, typescript-compile 0.7m
- build-zlib-ng, build-aws-sdk, build-ffmpeg, build-imagemagick 0.5m each (restored from artifacts)

### Release Linux (35m)

- app-smoke-tests 28m: smoke tests 27m (68 scenarios, 2 at once, about 48s each)
- zig-unit-tests 6.6m: tests 5.5m
- app-build 4.6m: build 3.6m
- cli-smoke-tests 3.9m: tests 2.8m
- cli-build 2.9m: build 2.4m
- typescript-unit-tests 1.4m, package 0.9m, typescript-compile 0.7m, the four library jobs 0.3m each

### Release macOS x64 (35m)

- app-smoke-tests 14.8m: smoke tests 11.6m (2 at once, about 20s each), setup 3.2m
- app-build 9.7m: build 7m, of which the Zig library in ReleaseSafe is 3.8m, Xcode 1.5m and the page (Vite) 0.5m
- cli-smoke-tests 7.7m: tests 4.9m
- cli-build 7.6m: build 5.2m
- zig-unit-tests 5.5m: tests 2.6m
- package 2.7m, typescript-unit-tests 1.1m, the four library jobs 0.8m to 1.3m each

### Release Android (31m)

- app-smoke-tests 20.9m: smoke tests 17.4m, of which the emulator start is about 4m and the 68 scenarios, one at a time, 13.5m
- zig-unit-tests 8.7m: tests 7.4m
- app-build 7.8m: build 5.5m, Android C library 1.2m
- the four library jobs 1.4m to 1.6m each, nearly all of it setting up the Android C library
- typescript-unit-tests 1.4m, typescript-compile 0.5m

### Release macOS arm64 (28m)

- app-smoke-tests 9.3m: smoke tests 8.1m (2 at once, about 14s each)
- app-build 6.2m: build 4.7m
- cli-smoke-tests 5.9m: tests 3.4m, media tools 1m
- zig-unit-tests 5.2m: tests 2.5m, media tools 0.8m
- cli-build 5.1m: build 3.6m
- package 1.5m, typescript-unit-tests 1.1m

### Release Windows (28m)

- app-smoke-tests 18.7m: smoke tests 15.9m (2 at once, about 27s each), setup 2.8m
- cli-smoke-tests 8.2m: tests 5.8m
- app-build 6m: build 3.2m
- cli-build 6m: build 4.4m
- zig-unit-tests 5.6m: tests 2.5m
- package 2.1m, typescript-unit-tests 1.3m, the four library jobs about 1m each

### CI (12m)

- zig-unit-tests-linux 8.3m: tests 7m
- app-build-linux 4.7m: build 3.8m
- cli-build-linux 2.4m: build 1.9m
- typescript-unit-tests 1.5m, typescript-compile 0.5m, the four library jobs 0.3m each

## Runner use

| Runner | Jobs | Job minutes |
| --- | --- | --- |
| ubuntu-latest | 48 | 123 |
| macos-latest (arm64) | 17 | 84 |
| macos-15-intel | 10 | 52 |
| windows-latest | 10 | 50 |

- The repository is public, on the free plan: at most 20 jobs at once and at most 5 of them on macOS. The peak in this set was 16 jobs at
  once and 5 on macOS.
- The three macOS workflows (iOS, macOS arm64, macOS x64) share the 5 macOS slots. 136 macOS job minutes over 5 slots is 27 minutes at
  best, whatever the jobs are. macOS jobs waited 2.5 minutes for a runner on average, and app-build waited 4 to 6 minutes.
- Each job spends 1 to 3 minutes on setup (checkout, Bun, Node, Zig, the Bun cache, the media tools, the libraries) before its own work.

## Where the time goes

1. The app smoke tests are the slowest job on every platform and the critical path of every release workflow. On one runner each,
   iOS and Android run one scenario at a time and the desktop platforms two.
2. The macOS slot limit: the macOS workflows queue behind each other, so macOS job minutes have to fall for any of the three to be fast.
3. The TypeScript compile and unit tests run seven times a push, once in every workflow, on the same Linux runner and the same code.
4. CI repeats the Linux release workflow's app build, CLI build and Zig unit tests.
5. iOS repeats the macOS arm64 Zig unit tests.
6. The app and CLI builds compile the Zig code in ReleaseSafe, which on macOS x64 is nearly 4 minutes of a 7 minute build.
7. Every push also packages every platform and publishes a nightly release.
