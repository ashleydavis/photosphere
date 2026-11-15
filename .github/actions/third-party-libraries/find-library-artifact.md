# find-library-artifact.sh

Finds a build of one third-party library that a workflow run on any branch uploaded as an artifact. The `build-*` actions run it to decide whether to download the library or build and upload it. GitHub Actions caches are scoped to a branch, but artifacts can be downloaded from any branch.

## Usage

```
bash .github/actions/third-party-libraries/find-library-artifact.sh <name-prefix> <key>
```

- `<name-prefix>`: the start of the artifact's name, the library and the platform, such as `aws-sdk-linux-x64`.
- `<key>`: everything the build depends on, as the action works it out.

The artifact's name is `<name-prefix>-<sha256 of key and runner image>`, because artifact names may not hold the `/` and `:` that the build arguments do. The runner image is the `ImageOS` variable every GitHub-hosted runner sets (such as `ubuntu24`). It is in the hash because a library built for the native target takes the libc of the image that built it, and one built on a newer image fails to link on an older one. The script fails when `ImageOS` is not set.

It needs `GH_TOKEN` with `actions: read`. It writes `name` and `run-id` to `$GITHUB_OUTPUT`. An empty `run-id` means there is no unexpired artifact of that name and the library has to be built. An error from the GitHub API fails the script.
