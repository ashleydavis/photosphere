# Release notes

`release-notes.sh` prints the release notes for a build: one bullet per commit made since the last release tag, newest first.

It exists so the two places that publish a build describe it the same way. The GitHub release workflow (`.github/workflows/release.yml`) uses it for the notes on a release or nightly, and the Android tester distribution (`apps/android-frontend/scripts/distribute-android.sh`) uses it for the notes a tester reads beside the build in Firebase App Tester. Written twice, those two would drift.

## Using it

```
bash ./scripts/release-notes.sh
bash ./scripts/release-notes.sh --prefix cli
bash ./scripts/release-notes.sh --prefix cli --exclude-tag v0.0.9 --empty-message "- No CLI-related commits found"
```

The notes go to stdout and nothing else does, so a caller can capture them directly. Which tag the notes were measured from goes to stderr, where it shows up in a workflow log without landing in the notes.

## Arguments

- `--prefix <word>` keeps only commits whose subject starts with `<word>:` and strips that prefix from the bullet. The release workflow passes `cli`, so a GitHub release lists the CLI changes and nothing else. Without it every commit is listed, which is what the Android tester builds want.
- `--exclude-tag <tag>` ignores that tag when looking for the last release tag. The release workflow passes the tag it is building, so a tagged release reports what changed since the tag before it instead of reporting nothing. For a nightly the workflow's tag output is empty, which excludes nothing.
- `--empty-message <text>` is printed when no commit matches, instead of empty output (default: `- No changes found`).
- `--limit <n>` keeps only the newest n bullets and adds a final one saying how many older changes were left out. The Android tester builds pass a limit because Firebase App Distribution rejects long release notes; a GitHub release has no such limit, so the workflow passes none.

## What counts as the last release tag

The newest tag by version number, skipping `nightly`, which moves with every nightly build and so would report almost nothing, and skipping whatever `--exclude-tag` names. Merge commits are left out of the notes. With no tag to measure from, in a repository that has never been tagged or a clone whose tags were not fetched, the range is the whole history.

That last case is worth knowing about when the notes come out longer than expected: a shallow checkout without tags produces a bullet for every commit ever made. The release workflow checks out with `fetch-depth: 0`, so it has the tags.
