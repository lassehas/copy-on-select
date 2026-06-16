#!/usr/bin/env bash
#
# build-dmg.sh — Build a Release .app and package it into a distributable .dmg.
#
# This produces an UNSIGNED-for-distribution DMG: the app is signed with whatever
# automatic identity Xcode picks (an Apple Development cert here), which is fine
# for running on this Mac. On OTHER Macs, Gatekeeper will warn ("unidentified
# developer"); recipients bypass via right-click → Open. For clean distribution
# you'd need Developer ID signing + notarization (not done here).
#
# Usage:
#   ./scripts/build-dmg.sh            # build + package into dist/
#
set -euo pipefail

# --- Config ----------------------------------------------------------------
PROJECT="copy-on-select.xcodeproj"
SCHEME="copy-on-select"
CONFIGURATION="Release"
APP_NAME="copy-on-select"          # PRODUCT_NAME / built .app base name

# Resolve repo root from this script's location, so it works from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/build"        # xcodebuild output (gitignored)
DIST_DIR="$ROOT_DIR/dist"          # final .dmg output (gitignored)

# --- Read version from the project for the DMG filename --------------------
VERSION="$(
  /usr/bin/sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' \
    "$PROJECT/project.pbxproj" | head -n1
)"
VERSION="${VERSION:-1.0}"

DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "==> Building $SCHEME ($CONFIGURATION) v$VERSION"

# --- 1. Clean build --------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  clean build \
  | grep -E '^(===|\*\* |error:|warning:)' || true

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi
echo "==> Built: $APP_PATH"

# --- 2. Stage DMG contents -------------------------------------------------
STAGE_DIR="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# Copy the app and add an Applications symlink for drag-to-install.
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# --- 3. Create the compressed DMG ------------------------------------------
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

echo "==> DMG created: $DMG_PATH"
echo "    size: $(du -h "$DMG_PATH" | cut -f1)"
