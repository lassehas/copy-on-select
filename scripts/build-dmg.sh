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
#   ./scripts/build-dmg.sh --release  # also tag vX.Y and publish a GitHub
#                                      # release with the DMG attached (needs gh)
#
set -euo pipefail

# --- Args ------------------------------------------------------------------
DO_RELEASE=false
for arg in "$@"; do
  case "$arg" in
    --release) DO_RELEASE=true ;;
    -h|--help)
      /usr/bin/sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "error: unknown argument '$arg' (use --release or --help)" >&2; exit 2 ;;
  esac
done

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
TAG="v${VERSION}"

# --- Release pre-flight (fail fast before the build) -----------------------
if [[ "$DO_RELEASE" == true ]]; then
  command -v gh >/dev/null || {
    echo "error: --release needs the GitHub CLI ('gh'); install it first." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || {
    echo "error: gh is not authenticated; run 'gh auth login'." >&2; exit 1; }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: release $TAG already exists. Bump MARKETING_VERSION first." >&2
    exit 1
  fi
fi

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

# --- 4. Publish a GitHub release (optional) --------------------------------
if [[ "$DO_RELEASE" == true ]]; then
  echo "==> Publishing GitHub release $TAG"

  # Tag the current commit and push it (skip if the tag already exists locally).
  if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag "$TAG"
  fi
  git push origin "$TAG"

  NOTES="Automatically copies selected text to the clipboard, system-wide — the terminal 'copy-on-select' behavior, brought to all of macOS as a background menu-bar app.

## Install
1. Download **${DMG_NAME}** below.
2. Open it and drag **${APP_NAME}** to **Applications**.
3. Launch it. Because the app is not notarized, macOS Gatekeeper will warn the first time — **right-click the app → Open** (or run \`xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app\`).
4. From the menu-bar icon, choose **Grant Accessibility Access…** and enable **${APP_NAME}** under System Settings → Privacy & Security → Accessibility.

## Usage
With the toggle on and Accessibility granted, just select text — by mouse drag or Shift+arrows — and it lands on your clipboard automatically.

## Requirements
- macOS 15.7+

> Note: this build is signed for local use but **not notarized**, so it shows a Gatekeeper warning on first launch (see install step 3). Accessibility permission must be granted on each machine."

  gh release create "$TAG" "$DMG_PATH" \
    --title "$APP_NAME $TAG" \
    --target "$(git rev-parse HEAD)" \
    --notes "$NOTES"

  echo "==> Released: $(gh release view "$TAG" --json url --jq .url)"
fi
