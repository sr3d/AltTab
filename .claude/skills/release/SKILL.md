---
name: release
description: Cut a new AltTab release end to end - regenerate README screenshots, commit and push pending work, pick the version bump, run ./release, then watch the GitHub build and verify the published DMG. Use when the user asks for a new release, to ship, publish, or tag a version, or runs /release.
---

# Release AltTab

`./release` does the version bump, the README Download link, the commit, the tag and the push.
GitHub (`.github/workflows/release.yml`) then builds the DMG and zip and publishes the release.
This skill is the checklist around it. Optional argument: `patch`, `minor`, `major` or `X.Y.Z`.

## 1. Check the starting point

```sh
git fetch -q origin && git status -sb
```

- Be on `main`, in sync with `origin/main`. If behind, `git pull --ff-only`. If on a feature
  branch, ask before merging it into `main`.
- Note the current version: `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist`.

## 2. Commit pending work (if any)

If the tree has changes:

1. Build: `swift build` must succeed.
2. Regenerate the README screenshots, as CLAUDE.md asks (only at commit time):
   `.build/debug/AltTab --screenshots docs`. Look at `docs/switcher.png` to check it rendered.
3. Make sure README.md describes any user-visible change.
4. Commit with a message that summarises the changes (with the attribution trailer), then
   `git push origin main`.

If the tree is clean, skip to step 3.

## 3. Pick the version

Use the user's argument if given. Otherwise choose from the commits since the last tag
(`git log --oneline $(git describe --tags --abbrev=0 --match 'v*')..HEAD`):

- `patch`: fixes and small tweaks only.
- `minor`: new features or changed behaviour.
- `major`: only if the user asks.

If nothing changed since the last tag, stop and tell the user there's nothing to release.

## 4. Release

```sh
./release -y <patch|minor|major|X.Y.Z>
```

It refuses when not on `main`, when the tree is dirty, when out of sync with `origin/main`,
or when the tag already exists. Fix the cause and re-run; don't work around its checks.

## 5. Watch the build and verify

```sh
ID=$(gh run list -L 1 --workflow release.yml --json databaseId -q '.[0].databaseId')
gh run watch "$ID" --exit-status --interval 15
gh release view vX.Y.Z --json assets -q '.assets[] | "\(.name) \(.size)"'
curl -sLI "https://github.com/sr3d/AltTab/$(grep -o 'releases/download/[^"]*' README.md)" | grep '^HTTP' | tail -1
```

- The run should succeed, the release should have `AltTab-X.Y.Z.dmg` and `AltTab-X.Y.Z.zip`,
  and the README's Download link should return `HTTP/2 200`.
- If the build fails: `gh run view "$ID" --log-failed`, fix it on `main`, push, then rebuild
  the same tag from the Actions tab (Release -> Run workflow -> the tag) or with
  `gh workflow run release.yml -f tag=vX.Y.Z`. Don't delete or move a pushed tag without
  asking.

## 6. Report

Give the user the release URL (`https://github.com/sr3d/AltTab/releases/tag/vX.Y.Z`), the
version change (old -> new) and why that bump, what went into it, and the verification
results. Say plainly if any step failed or was skipped.

## Alternative without a terminal

Actions tab -> **Make New Release** -> Run workflow does steps 3-4 on GitHub (and then builds
and publishes). It doesn't regenerate screenshots or commit pending work.
