# AltTab

## Screenshots: update only when committing

Don't regenerate the README screenshots (`.build/debug/AltTab --screenshots docs`) while a
feature is still being iterated on. Do it once, as part of committing the finished change,
so the images match what's committed.

For visual checks during development, render into a scratch directory instead of `docs/`.
