# Release notes

Notes for tag `vX.Y.Z` live in `vX.Y.Z.md` in this directory (e.g. `v2.1.0.md`
for the `v2.1.0` tag).

When a tag is pushed, the Release workflow
([`.github/workflows/release.yml`](../../.github/workflows/release.yml))
builds the DMG and creates the GitHub release. If a matching notes file exists
here it becomes the release body; otherwise GitHub's auto-generated notes are
used. Write the file in plain Markdown — it's published verbatim.
