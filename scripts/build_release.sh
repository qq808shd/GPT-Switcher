#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$PROJECT_ROOT/dist"
STAGING="$(mktemp -d /private/tmp/GPTSwitcherRelease.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/GPT Switcher.app"
CONTENTS="$APP/Contents"
FINAL_APP="$DIST/GPT Switcher.app"

cd "$PROJECT_ROOT"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
SOURCE_PATH_MAP="$PROJECT_ROOT=."
BUILD_ARGS=(
    --disable-sandbox
    --cache-path "$PROJECT_ROOT/.build/cache"
    --config-path "$PROJECT_ROOT/.build/config"
    --security-path "$PROJECT_ROOT/.build/security"
    -Xswiftc -debug-prefix-map
    -Xswiftc "$SOURCE_PATH_MAP"
    -Xswiftc -file-prefix-map
    -Xswiftc "$SOURCE_PATH_MAP"
)
swift build "${BUILD_ARGS[@]}" -c release --product GPTSwitcher
swift build "${BUILD_ARGS[@]}" -c release --product gpt-switcher
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" -c release --show-bin-path)"

rm -rf "$FINAL_APP" "$DIST/GPT Switcher.dmg" "$DIST/GPT Switcher.app.zip" "$DIST/AppIcon.iconset"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/GPTSwitcher" "$CONTENTS/MacOS/GPTSwitcher"
cp "$BIN_DIR/gpt-switcher" "$DIST/gpt-switcher"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Swift release binaries retain linker symbol records containing absolute
# object-file paths. Strip debug symbols before signing/distribution so build
# machine usernames and checkout locations cannot leak through the archives.
/usr/bin/strip -S "$CONTENTS/MacOS/GPTSwitcher"
/usr/bin/strip -S "$DIST/gpt-switcher"

xcrun swift "$PROJECT_ROOT/scripts/generate_icon.swift" "$STAGING/AppIcon.iconset" "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$STAGING/AppIcon.iconset"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
hdiutil create -volname "GPT Switcher" -srcfolder "$APP" -ov -format UDZO "$STAGING/GPT Switcher.dmg"
ditto -c -k --keepParent --norsrc "$APP" "$STAGING/GPT Switcher.app.zip"

# Documents may be backed by a File Provider that attaches Finder metadata to .app
# directories. The signed source and DMG are verified in /private/tmp first.
ditto --norsrc "$APP" "$FINAL_APP"
cp "$STAGING/GPT Switcher.dmg" "$DIST/GPT Switcher.dmg"
cp "$STAGING/GPT Switcher.app.zip" "$DIST/GPT Switcher.app.zip"

printf 'Built:\n  %s\n  %s\n  %s\n  %s\n' "$FINAL_APP" "$DIST/GPT Switcher.dmg" "$DIST/GPT Switcher.app.zip" "$DIST/gpt-switcher"
