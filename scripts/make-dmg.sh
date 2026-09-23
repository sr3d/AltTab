#!/usr/bin/env bash
# Builds build/AltTab.app and packages it for release:
#   build/AltTab-<version>.dmg   drag-to-Applications disk image
#   build/AltTab-<version>.zip   the app, zipped
# Used by CI (.github/workflows); works locally too.
#
#   ./scripts/make-dmg.sh             build the app, then package it
#   ./scripts/make-dmg.sh --no-build  package the existing build/AltTab.app
#
# Environment: everything scripts/build-app.sh takes (ALTTAB_UNIVERSAL, ALTTAB_SIGN_IDENTITY,
# ALTTAB_BUILD), plus
#   ALTTAB_VERSION  version for Info.plist and the file names (default: the v* tag on HEAD
#                   without the "v", else 0.0.0-dev+<short sha>)
# In GitHub Actions the version and file paths are also written to $GITHUB_OUTPUT
# (version, dmg, zip).
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

VERSION="${ALTTAB_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    TAG="$(git describe --tags --exact-match --match 'v*' 2>/dev/null || true)"
    VERSION="${TAG#v}"
fi
[[ -n "$VERSION" ]] || VERSION="0.0.0-dev+$(git rev-parse --short HEAD)"
export ALTTAB_VERSION="$VERSION"

APP="build/AltTab.app"
if [[ "$BUILD" == "1" ]]; then
    ./scripts/build-app.sh --no-install
fi
[[ -d "$APP" ]] || { echo "missing $APP; run without --no-build" >&2; exit 1; }

DMG="build/AltTab-$VERSION.dmg"
ZIP="build/AltTab-$VERSION.zip"
RW="build/AltTab-rw.dmg"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/alttab-dmg.XXXXXX")"
rm -f "$DMG" "$ZIP" "$RW"

# Not `hdiutil create -srcfolder`: its temporary volume often can't be unmounted ("Resource
# busy") while Spotlight or the malware scan look at the new app. Fill a read-write image
# ourselves, so the unmount can be retried and forced, then compress it.
SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 20 ))
hdiutil create -quiet -size "${SIZE_MB}m" -fs HFS+ -volname "AltTab $VERSION" -ov "$RW"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$RW"
touch "$MOUNT/.metadata_never_index"   # keeps Spotlight off the volume (hidden)
ditto "$APP" "$MOUNT/AltTab.app"
ln -s /Applications "$MOUNT/Applications"
sync
for attempt in 1 2 3 4 5; do
    hdiutil detach -quiet "$MOUNT" && break
    echo "detach busy; retrying ($attempt)" >&2
    sleep "$attempt"
    [[ "$attempt" == 5 ]] && hdiutil detach -force "$MOUNT"
done
rmdir "$MOUNT" 2>/dev/null || true
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
hdiutil verify -quiet "$DMG"

ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "version=$VERSION"; echo "dmg=$DMG"; echo "zip=$ZIP"; } >> "$GITHUB_OUTPUT"
fi
echo "Built $DMG"
echo "Built $ZIP"
