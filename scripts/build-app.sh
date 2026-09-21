#!/usr/bin/env bash
# Builds build/AltTab.app and (by default) installs it to ~/Applications.
#
#   ./scripts/build-app.sh            build, sign, install
#   ./scripts/build-app.sh --open     ...and launch it
#   ./scripts/build-app.sh --no-install   build and sign only (CI)
#
# Environment:
#   ALTTAB_SIGN_IDENTITY  codesign identity; "-" forces ad-hoc (default: "AltTab Dev", else the
#                         first "Apple Development" cert, else ad-hoc)
#   ALTTAB_UNIVERSAL=1    build arm64 + x86_64 (needs full Xcode, not just Command Line Tools)
#   ALTTAB_VERSION        version string written to Info.plist (e.g. 1.2.0 from a git tag)
#   ALTTAB_BUILD          build number written to Info.plist
#
# A stable signing identity keeps the Accessibility grant across rebuilds; ad-hoc signatures
# change on every build, and macOS then treats the app as new.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --open) OPEN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP="build/AltTab.app"
DEST="$HOME/Applications/AltTab.app"

if [[ "${ALTTAB_UNIVERSAL:-0}" == "1" ]]; then
    swift build -c release --product AltTab --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/AltTab"
else
    swift build -c release --product AltTab
    BIN=".build/release/AltTab"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AltTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${ALTTAB_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${ALTTAB_VERSION}" "$APP/Contents/Info.plist"
fi
if [[ -n "${ALTTAB_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${ALTTAB_BUILD}" "$APP/Contents/Info.plist"
fi

IDENTITY="${ALTTAB_SIGN_IDENTITY:-AltTab Dev}"
if [[ "$IDENTITY" != "-" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! grep -q "\"$IDENTITY\"" <<<"$IDENTITIES"; then
        # Any stable identity works; prefer an existing Apple Development cert.
        IDENTITY="$(sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)"
    fi
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
    echo "Signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Signing ad-hoc. Accessibility must be re-granted after each rebuild; see README." >&2
    codesign --force --sign - "$APP"
fi

[[ "$INSTALL" == "1" ]] || { echo "Built $APP"; exit 0; }

pkill -x AltTab 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
[[ "$OPEN" == "1" ]] && open "$DEST"
exit 0
