#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=${APP_NAME:-nodaysidle}
BUNDLE_ID=${BUNDLE_ID:-com.nodaysidle.browser}
export APP_NAME BUNDLE_ID

SOURCE="$ROOT/${APP_NAME}.app"
TARGET="/Applications/${APP_NAME}.app"
BACKUP=""

bash "$ROOT/Scripts/package_app.sh" release

if [[ ! -d "$SOURCE" || ! -f "$SOURCE/Contents/Info.plist" ]]; then
  echo "Packaged app is missing: $SOURCE" >&2
  exit 1
fi

if ! source_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$SOURCE/Contents/Info.plist"); then
  echo "Could not read the packaged bundle identifier: $SOURCE" >&2
  exit 1
fi
if [[ "$source_bundle_id" != "$BUNDLE_ID" ]]; then
  echo "Packaged bundle identifier '$source_bundle_id' does not match expected '$BUNDLE_ID'" >&2
  exit 1
fi

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 0.5

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  if [[ -L "$TARGET" || ! -d "$TARGET" || ! -f "$TARGET/Contents/Info.plist" ]]; then
    echo "Refusing to replace non-application target: $TARGET" >&2
    exit 1
  fi

  target_bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$TARGET/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$target_bundle_id" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace bundle '$target_bundle_id' at $TARGET (expected '$BUNDLE_ID')" >&2
    exit 1
  fi

  BACKUP="$TARGET.previous.$(date +%Y%m%d-%H%M%S).app"
  if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
    echo "Backup path already exists; refusing to overwrite it: $BACKUP" >&2
    exit 1
  fi
  ditto "$TARGET" "$BACKUP"
  if [[ ! -d "$BACKUP/Contents" ]]; then
    echo "Could not verify the previous app backup: $BACKUP" >&2
    exit 1
  fi
  rm -rf "$TARGET"
fi

ditto "$SOURCE" "$TARGET"
xattr -cr "$TARGET" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$TARGET"

# Refresh Launch Services registration for the installed bundle.
touch "$TARGET"
if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
fi

if [[ -n "$BACKUP" ]]; then
  echo "Previous installation backed up at $BACKUP"
fi
echo "Installed $TARGET"
