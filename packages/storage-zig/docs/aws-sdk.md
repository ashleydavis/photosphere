# The AWS SDK for C in storage-zig

`storage-zig` talks to S3 through the official AWS SDK for C: aws-c-s3 and the libraries under it. `src/lib/s3-client.zig` is a thin binding to it (the SDK signs, sends, resolves endpoints, uploads in parts and parses XML); `src/lib/cloud-storage.zig` uses the binding the way the TypeScript `CloudStorage` uses `@aws-sdk/client-s3` and `@aws-sdk/lib-storage`.

The libraries are ordinary Zig package dependencies: `build.zig.zon` pins each one to the unmodified release archive on GitHub (URL and hash), and `build.zig` compiles their C sources with Zig, so `zig build` needs nothing installed and cross-compiles like the rest of the Zig code for Linux and Windows. macOS is built natively on a Mac with the macOS SDK (see [Platforms](#platforms)). Nothing from the SDK is copied into this repository or patched.

## Libraries and versions

The versions are the set aws-crt-cpp **v0.43.7** pins as its git submodules (`crt/*` in that tag), which AWS releases and tests together.

| Library | Tag | Used for |
| --- | --- | --- |
| [aws-c-common](https://github.com/awslabs/aws-c-common) | v0.14.5 | Allocators, strings, URIs, XML parser, threads |
| [aws-checksums](https://github.com/awslabs/aws-checksums) | v0.2.10 | CRC checksums (aws-c-s3 links it) |
| [aws-c-cal](https://github.com/awslabs/aws-c-cal) | v0.9.15 | Hashes and HMAC for signing, MD5 |
| [aws-c-io](https://github.com/awslabs/aws-c-io) | v0.27.6 | Event loops, sockets, DNS, TLS |
| [aws-c-compression](https://github.com/awslabs/aws-c-compression) | v0.3.2 | HPACK (aws-c-http links it) |
| [aws-c-http](https://github.com/awslabs/aws-c-http) | v0.11.0 | HTTP/1.1 connections and connection pools |
| [aws-c-sdkutils](https://github.com/awslabs/aws-c-sdkutils) | v0.2.9 | The endpoint rules engine |
| [aws-c-auth](https://github.com/awslabs/aws-c-auth) | v0.10.4 | Credentials providers, SigV4 signing |
| [aws-c-s3](https://github.com/awslabs/aws-c-s3) | v0.13.5 | The S3 client, multipart uploads, the S3 endpoint rules |
| [aws-lc](https://github.com/aws/aws-lc) | v5.5.0 | libcrypto on Linux (and for s2n-tls on macOS) |
| [s2n-tls](https://github.com/aws/s2n-tls) | v1.7.7 | TLS on Linux (and on macOS when chosen at run time) |

aws-lc and s2n-tls are lazy dependencies: they are only fetched when building for Linux or macOS.

## How they are built

Each library has a file in `aws/` that mirrors its `CMakeLists.txt` for a Release, static build: the same source files (a CMake `file(GLOB ...)` is a directory listing in `aws/aws-sdk.zig`, so files a release adds or removes in a globbed directory are picked up without a change here; explicit CMake lists, as in aws-lc, are copied in the same order), the same include paths, the same compile definitions, and the same generated config header (`aws/common/config.h` from `config.h.in`). `aws/aws-sdk.zig` builds them in dependency order and links them into the `storage-zig` module.

Where a CMake file probes the compiler (`check_c_source_compiles`, `check_symbol_exists`, `try_compile`), the result for each target is written into the Zig file with a comment naming the probe. The results were obtained by compiling the probe sources with `zig cc -target <target>`, the compiler the build uses (for macOS, `-target x86_64-macos` and `-target aarch64-macos`: the probes only use C library headers, which Zig ships for macOS). A `-march=...` flag of a probe is given as the equivalent `-mcpu=<model>+<features>`, since `zig cc` reads `-march` as a CPU model name. The libraries are always compiled with `ReleaseFast` and without debug information, the equivalent of CMake's Release (`-O3 -DNDEBUG`), whatever mode the Zig code is built in.

What differs from a CMake build, and why:

- Compiler warning flags (`-Wall`, `-Wextra`, `-Werror` and so on) are not passed: they change what the compiler reports, not the code it produces.
- `-mtune=neoverse-v1` (aws-checksums on ARM64) is not passed: it only tunes instruction scheduling. The `-march=armv8-a+crc+crypto`, `-mavx2` and similar per-file flags are passed as the equivalent Zig CPU features, since Zig chooses the CPU features of a compilation itself.
- aws-lc is built from the files it ships pre-generated in `generated-src` (its documented build without Perl and Go), and with its `ENABLE_SOURCE_MODIFICATION` behaviour off (it would rewrite `include/openssl/base.h` in the source tree, which is already the configured copy in a release).
- aws-c-s3 is built with its `AWS_ENABLE_S3_ENDPOINT_RESOLVER` option on, because the binding resolves endpoints with the S3 endpoint rules (`aws_s3_endpoint_resolver_new`), the same rules the JavaScript SDK applies.
- The SDK headers are preprocessed with `zig cc -E` before `translate-c` turns them into the `aws-c` Zig module: translate-c's own preprocessor cannot expand the argument-counting macros in `aws/common/macros.h`. `struct aws_signing_config_aws` has a bit-field, which translate-c cannot represent, so `s3-client.zig` declares it field for field (`SigningConfigAws`); a unit test fills it through the SDK (aws_s3_init_default_signing_config) and checks the values read back through it, and the mock S3 server of the tests signs every request again with it and compares the signatures.

## Platforms

| Target | Crypto | TLS | Event loop | Built on |
| --- | --- | --- | --- | --- |
| x86_64-linux, aarch64-linux | aws-lc | s2n-tls | epoll | any host |
| x86_64-windows | BCrypt and NCrypt | SChannel | I/O completion ports | any host |
| x86_64-macos, aarch64-macos | CommonCrypto and the Security framework | Secure Transport, or s2n-tls over aws-lc | kqueue (dispatch queue also built) | a Mac of the same architecture |

On macOS the files in `aws/` follow the CMake files' `APPLE` branches with their default options:

- aws-c-common: `source/posix`, `source/darwin` (no such directory in this release, so nothing), the `platform_fallback_stubs`, and `source/arch/arm/darwin` on aarch64 (`source/arch/intel` on x86_64, as on Linux). No `_POSIX_C_SOURCE`/`_XOPEN_SOURCE`, no thread affinity, `pthread_getname_np` with 3 arguments. It links `dl` and the CoreFoundation framework.
- aws-c-cal: `source/darwin` (CommonCrypto and the Security framework), `ed25519_noop.c` and `ref_hkdf.c`; it links the Security and CoreFoundation frameworks and not libcrypto.
- aws-c-io: `source/bsd` (kqueue), `source/posix`, `source/darwin` (the dispatch queue event loop, Network framework sockets and Secure Transport) and, because `USE_S2N` is on by default when `AWS_USE_SECITEM` is not defined, `source/s2n`. Both `AWS_ENABLE_DISPATCH_QUEUE` and `AWS_ENABLE_KQUEUE` are defined; kqueue is the default event loop. Secure Transport is the TLS implementation unless the `AWS_CRT_USE_NON_FIPS_TLS_13` environment variable is set, which selects s2n-tls. It links the Security and Network frameworks.
- aws-lc and s2n-tls are built as on Linux (aws-crt-cpp builds them on macOS too), with aws-lc's `generated-src/mac-x86_64` and `generated-src/ios-aarch64` assembly, without the Linux-only `_XOPEN_SOURCE=700` and `HAVE_LINUX_RANDOM_H`, and with s2n-tls' macOS probe results.

On Apple, aws-c-common (`allocator.c`, `common.c`), aws-c-cal and aws-c-io (their `source/darwin` files, and aws-c-io's `s2n_apple_keychain.c` and `s2n_tls_channel_handler.c`) and aws-lc's jitterentropy include headers of the CoreFoundation, CoreServices, Security and Network frameworks, which Zig does not ship. Zig uses the macOS SDK only for a native build: when the target's operating system and ABI are not given, it finds the SDK of Xcode or the Command Line Tools with `xcode-select --print-path` and `xcrun --sdk macosx --show-sdk-path` (`std/zig/system/darwin.zig`) and compiles against the SDK's `usr/include` and `System/Library/Frameworks` (`std/zig/LibCDirs.zig`, `std/zig/system/NativePaths.zig`), which is also what CMake does on a Mac (aws-c-cal's CMakeLists.txt sets the sysroot from `xcrun --show-sdk-path`). So macOS is built on a Mac with no `-Dtarget`; `zig build` for a macOS target given with `-Dtarget` stops with an error that says so, on any host.

The Zig CLI (`apps/cli-zig`) is built for macOS with `bun run build-mac-arm64` on an Apple Silicon Mac and `bun run build-mac-x64` on an Intel Mac. Both run `zig build -Dcpu=baseline`: the operating system and ABI stay native, so the SDK is used, and the CPU is the baseline of the architecture on macOS (Apple M1 for aarch64), the CPU the former `-Dtarget=<arch>-macos` builds had. Being native, the binary's minimum macOS version is the version of the Mac that builds it. Each script builds for the Mac it runs on, so run it on a Mac of the matching architecture (CI checks the architecture with `file`). `bun run build-all` cross-compiles the Linux and Windows targets on any host.

## Fetching the packages

`zig build` fetches every dependency listed in `build.zig.zon` from its GitHub URL, checks it against the hash, keeps it in Zig's global cache and extracts it into the project's `zig-pkg/` directory (git-ignored). CI needs nothing else; the release workflow caches the `p` directory of Zig's global cache (`zig env` prints the global cache directory: `~/.cache/zig` on Linux and macOS, `%LOCALAPPDATA%\zig` on Windows) keyed on the `build.zig.zon` files, which avoids downloading the archives again.

Where `zig fetch` cannot reach GitHub but `git clone` works (a proxy that only allows git, for example), a package can be put into the cache from a local archive of the same tag. `git archive` produces the same files GitHub's archive has, and Zig hashes the files, not the archive, so the hash is the one in `build.zig.zon`:

```
git clone --depth 1 --branch v0.13.5 https://github.com/awslabs/aws-c-s3.git
git -C aws-c-s3 archive --format=tar.gz --prefix=aws-c-s3-0.13.5/ v0.13.5 -o "$PWD/aws-c-s3-v0.13.5.tar.gz"
cd packages/storage-zig && zig fetch "$OLDPWD/aws-c-s3-v0.13.5.tar.gz"
```

`zig fetch` prints the hash; it must match the one in `build.zig.zon`.

## Upgrading

1. Pick the new aws-crt-cpp release, and read the tag each submodule under `crt/` points at (`git ls-tree <tag> crt/` in a clone of aws-crt-cpp, then `git ls-remote --tags` on each library to find the tag of that commit).
2. For each library that changed, update its entry in `build.zig.zon`: `zig fetch --save=<name> https://github.com/<owner>/<name>/archive/refs/tags/<tag>.tar.gz` (or put the archive in the cache as above and change the `url` and `hash` by hand), and update the table above.
3. Diff the library's build files between the old and the new tag (`CMakeLists.txt`, `cmake/*.cmake`, and for aws-c-common `include/aws/common/config.h.in`) and carry every change into its file in `aws/`: new or removed directories, explicitly listed sources, compile definitions, options and their defaults, and probes. aws-lc lists its sources explicitly in `crypto/CMakeLists.txt`, `crypto/fipsmodule/CMakeLists.txt` and `third_party/jitterentropy/CMakeLists.txt`; compare those lists with the ones in `aws/aws-lc.zig`.
4. Evaluate any new or changed probe for each target with `zig cc -target <target>` (for s2n-tls: every `tests/features/*.c`, compiled with `-I <s2n-tls> -I <aws-lc>/include -include <s2n-tls>/utils/s2n_prelude.h -c`, the flags in `tests/features/GLOBAL.flags` and the probe's own `.flags` file) and update the results in `aws/`.
5. If the binding uses an API that changed, update `src/lib/s3-client.zig`. If `struct aws_signing_config_aws` changed, update `SigningConfigAws` to match.
6. Run the tests: `zig build test` in `packages/storage-zig`, `bun --filter '*-zig' test` from the repository root, `bun run build-all` in `apps/cli-zig`, and the Zig CLI smoke tests (`bun run test:cli:zig`), whose S3 tests run against a local MinIO server. The macOS configuration is only compiled on a Mac: the release workflow's `zig-smoke-tests` (macos-latest) and `build-zig-macos` (an Apple Silicon and an Intel runner) jobs run these there.
