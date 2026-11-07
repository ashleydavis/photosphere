# Remove useMemo

## Overview

`useMemo` is banned unless the human explicitly asks for it. This plan removes every use of it from the repository, computing each value directly in the render body instead, and adds the ban to the human's global React rules so new code does not bring it back. There are eight occurrences in two files: `packages/user-interface/src/stories/stories-page.tsx` (the import and four calls) and `packages/user-interface/src/pages/map/cluster-modal.tsx` (the import and two calls). `git grep -n "useMemo" -- apps packages` finds nothing else.

## Issues

## Steps

1. **Stories page, `StoriesPage`** (`packages/user-interface/src/stories/stories-page.tsx`):
    - Replace `const filteredStories = useMemo(() => { ... }, [searchText]);` with a plain computation: `const needle = searchText.trim().toLowerCase();` then `filteredStories` is `stories` when `needle` is empty, otherwise the same `stories.filter(...)` on id, name and category. Keep the comment block above it.
    - Replace `const grouped = useMemo(() => { ... }, [filteredStories]);` with `const grouped: { [category: string]: IStory[] } = {};` followed by the same two loops, writing into `grouped` instead of `result`. Keep the comment block.
    - Replace `const orderedStories = useMemo(() => { ... }, [grouped]);` with `const orderedStories: IStory[] = [];` followed by the same loop over `CATEGORY_ORDER`. Keep the comment block.
    - None of these three values is in an effect's dependency list, so nothing else changes for them.

2. **Stories page, `StoriesCycle`** (same file):
    - Replace `const steps: ICycleStep[] = useMemo(() => { ... }, [cycleStories]);` with `const themes: ThemeMode[] = ["light", "dark"];` and `const steps: ICycleStep[] = cycleStories.flatMap(story => themes.map(theme => ({ theme, story })));`. Keep the existing comments, and add to them that `steps` is rebuilt on every render, so the effects that read it depend on `cycleStories` instead.
    - `steps` is in two effects' dependency lists. A value rebuilt on every render would re-run them on every render (for example after `setMode` changes the colour scheme), which would restart the dwell and ready timers and log `STORIES CYCLE READY` more than once per story. Change the theme effect's dependencies from `[index, steps, setMode]` to `[index, cycleStories, setMode]`, and the per-story lifecycle effect's from `[index, steps, durationMs]` to `[index, cycleStories, durationMs]`. `cycleStories` is the `stories` array imported at module level and passed in by `StoriesPage`, so its identity never changes.
    - The completion effect depends on `steps.length`, a number, and stays as it is.
    - Remove `useMemo` from the `react` import on line 1.
    - Run `bun run compile` from the repository root. It exits 0.

3. **Cluster modal** (`packages/user-interface/src/pages/map/cluster-modal.tsx`):
    - Replace `const itemsMap = useMemo<IGalleryItemMap>(() => { ... }, [items]);` with `const itemsMap: IGalleryItemMap = {};` followed by the same loop that fills it. It is read only inside the `source` object's `getAssets` and `getItemById`, and `source` is already rebuilt on every render, so no effect or memo depends on it.
    - Replace `const defaultLocationName = useMemo<string | undefined>(() => { ... }, [items]);` with `const defaultLocationName: string | undefined = items.find(item => item.location)?.location;`. It is read only in the render body.
    - Remove `useMemo` from the `react` import on line 1.
    - Run `bun run compile` from the repository root. It exits 0.

4. **Confirm none are left.** Run `git grep -n "useMemo" -- apps packages`. It prints nothing.

5. **Test.** Run `bun run test` (unit tests), then `bun run tev` (the full set, which includes the Photosphere App smoke tests), then `bun run stories:ziggy -- --headless --no-screenshots` (the stories cycle, which plays every story including the cluster modal story, `packages/user-interface/src/stories/modals/cluster-modal.stories.tsx`). Each exits 0. The stories run must log `STORIES CYCLE COMPLETE` with no `STORIES CYCLE FAILED` line, and exactly one `STORIES CYCLE READY` line per step (count the READY lines in the app log the player reports and compare with the step count in the `STORIES CYCLE START` line).

6. **Documentation.** Add this rule to `~/agent-config/rules/react.md` (the human's global React rules, in the agent-config repository), as a bullet at the end of the list above `## Naming`: "`useMemo` is banned unless the human explicitly asks for it. Compute the value in the render body. Where an effect reads a value that is now rebuilt on every render, make the effect depend on the inputs the value is built from, not on the value." Follow `~/agent-config/rules/writing.md`. Do not touch any other file in that repository: `rules/testing.md` there already has uncommitted changes that are not part of this work.

## Unit Tests

None. Every change is inside a React component (`StoriesPage`, `StoriesCycle`, `ClusterGallerySource`/`ClusterModal`), and this repository does not unit test React components. No logic is added that would justify a `lib/` function. The existing unit tests run unchanged in step 5.

## Smoke Tests

- `bun run stories:ziggy -- --headless --no-screenshots` covers `StoriesPage` (the stories list and navigation), `StoriesCycle` (the per-story timers and the theme change, where a dependency mistake would show as repeated READY lines or a hung cycle) and the cluster modal story.
- `bun run tev` covers the Photosphere App smoke tests.

## Verify

- `bun run compile` exits 0.
- `git grep -n "useMemo" -- apps packages` prints nothing.
- `bun run test` exits 0.
- `bun run tev` exits 0.
- `bun run stories:ziggy -- --headless --no-screenshots` exits 0, with one `STORIES CYCLE READY` line per step and no `STORIES CYCLE FAILED` line.
- `~/agent-config/rules/react.md` contains the `useMemo` rule.

## Notes

- The human chose: no documentation review stop, and the rule goes in the global React rules (`~/agent-config/rules/react.md`) only, not in this project's `CLAUDE.md`.
- An earlier attempt at this change was reverted at the human's request. That attempt made the same edits as steps 1 to 3 but was never tested. This plan adds the stories cycle run to catch a dependency mistake in `StoriesCycle`.
- The repository runs no ESLint, so `react-hooks/exhaustive-deps` will not flag the `cycleStories` dependencies in step 2.
- `useCallback` is not covered by this plan. The request was for `useMemo` only.
- Nothing in this plan commits, pushes or deletes anything.
