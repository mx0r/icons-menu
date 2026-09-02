#!/usr/bin/env bash
#
# Build, sign and package Icons Menu as a DMG.
#
#   ./scripts/build-release.sh
#
# Output lands in builds/<date>-<version>/ and contains the .dmg, a readme for
# whoever installs it, and a SHA-256 checksum.
#
# Environment:
#   SIGN_IDENTITY   Signing identity. Defaults to "-" (ad hoc), which is what this
#                   machine has. Set to a "Developer ID Application: …" identity if
#                   one is ever available, and the script will use it and tell you
#                   how to notarise.
#   MARKETING_VERSION       Override the version in project.yml — CI sets this
#   CURRENT_PROJECT_VERSION from the git tag and the run number.
#
# There is no test step because the project has no test target. Add one here the
# day it gets one — packaging something untested should be a deliberate choice.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCHEME=IconsMenu
CONFIG=Release
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DERIVED="$REPO/.build/derived"
STAGE="$REPO/.build/stage"

# Version overrides, if any. Built as an array so an unset one passes nothing;
# the `[@]+` guard is for bash 3.2, which is what macOS ships and what errors on
# expanding an empty array under `set -u`.
VERSION_SETTINGS=()
[[ -n "${MARKETING_VERSION:-}" ]] && VERSION_SETTINGS+=("MARKETING_VERSION=$MARKETING_VERSION")
[[ -n "${CURRENT_PROJECT_VERSION:-}" ]] \
  && VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found — brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found — install Xcode"

# The icon is committed, but the app target references it, so a checkout without
# it cannot even generate the project. Render it rather than fail.
if [[ ! -f "$REPO/Resources/AppIcon.icns" ]]; then
  info "Rendering the app icon"
  make icon
fi

# The project is generated, never committed.
info "Generating Xcode project"
xcodegen generate

info "Building $CONFIG"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
  clean build >/dev/null 2>&1 \
  || fail "build failed (re-run without the redirect to see why)"

PRODUCT_NAME=$(xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -configuration "$CONFIG" -showBuildSettings \
  ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} 2>/dev/null \
  | awk -F' = ' '/ FULL_PRODUCT_NAME /{print $2; exit}')
APP="$DERIVED/Build/Products/$CONFIG/$PRODUCT_NAME"
[[ -d "$APP" ]] || fail "no app at $APP"
APP_NAME=$(basename "$APP" .app)

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info" CFBundleVersion)
BUNDLE_ID=$(defaults read "$APP/Contents/Info" CFBundleIdentifier)
# The bundle on disk is IconsMenu.app; everything a user reads calls it "Icons Menu".
DISPLAY_NAME=$(defaults read "$APP/Contents/Info" CFBundleName)
DATE=$(date +%Y-%m-%d)
OUT="$REPO/builds/$DATE-$VERSION"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

info "$DISPLAY_NAME $VERSION (build $BUILD), $BUNDLE_ID"

# --- stage ------------------------------------------------------------------

reset_dir() {
  local dir="$1"
  if [[ -e "$dir" ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash "$dir"
    else
      fail "$dir already exists and 'trash' is unavailable — move it aside yourself"
    fi
  fi
  mkdir -p "$dir"
}

reset_dir "$STAGE"
reset_dir "$OUT"

# ditto, not cp -R: it preserves the code signature and extended attributes.
ditto "$APP" "$STAGE/$APP_NAME.app"
# Drag-to-install target.
ln -s /Applications "$STAGE/Applications"

# --- sign -------------------------------------------------------------------

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  info "Signing ad hoc (no Developer ID on this machine)"
else
  info "Signing as $SIGN_IDENTITY"
fi

# No entitlements and no hardened runtime, matching project.yml: the app is not
# sandboxed and nothing it does needs either. Being an Accessibility client is a
# TCC grant, not an entitlement.
codesign --force --sign "$SIGN_IDENTITY" "$STAGE/$APP_NAME.app"

codesign --verify --strict --verbose=1 "$STAGE/$APP_NAME.app" \
  || fail "signature did not verify"

# --- readme for whoever installs it -----------------------------------------

cat > "$STAGE/Read Me.txt" <<EOF
$DISPLAY_NAME $VERSION (build $BUILD)
$(date '+%-d %B %Y')

Reaches every menu bar item on the system from one dropdown — including the ones
macOS has pushed off-screen, where clicking the icon is no longer an option.

INSTALL
  Drag $APP_NAME to the Applications folder in this window.

FIRST LAUNCH
  This app is signed ad hoc rather than with an Apple Developer ID, so macOS
  will refuse to open it on the first try. Right-click it in Applications and
  choose Open, then confirm. You only need to do this once.

  If macOS still refuses, clear the download flag:
      xattr -d com.apple.quarantine "/Applications/$APP_NAME.app"

ACCESSIBILITY PERMISSION
  Required, and the app is genuinely useless without it: every application
  reports an empty extras menu bar to an untrusted process, so the dropdown
  would simply be blank. $DISPLAY_NAME asks on first launch, and says so in the
  menu until it is granted.

  System Settings > Privacy & Security > Accessibility, if you miss the prompt.

  The grant is keyed to the code signature, and an ad-hoc signature changes with
  every build — so a new version has to be granted again. Toggling the existing
  switch off and on does not work; it re-approves the old signature. Remove the
  entry with the − button and let the new copy ask, or run:
      tccutil reset Accessibility $BUNDLE_ID

USING IT
  Click the $DISPLAY_NAME icon, or press ⌃⌥M anywhere to pop the menu at the
  pointer. The hotkey is the reliable route: it does not care where the icon is,
  or whether it is on screen at all.

  The dropdown lists one row per application, alphabetically. An app whose menu
  can be mirrored opens it as a submenu, exactly as the app itself offers it; an
  app without one is a single click that presses the item.

  On first launch $DISPLAY_NAME parks itself as far right as the bar allows, so it
  is the last third-party item macOS pushes off. Drag it elsewhere and that
  choice sticks.

  Settings… lists every item with its x position and flags the ones already
  off-screen.

With help from Claude.
EOF

# --- dmg --------------------------------------------------------------------

info "Building DMG"
hdiutil create \
  -volname "$DISPLAY_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

cp "$STAGE/Read Me.txt" "$OUT/Read Me.txt"
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )

if command -v trash >/dev/null 2>&1; then trash "$STAGE"; fi

info "Done"
echo
echo "  $DMG"
echo "  $(du -h "$DMG" | cut -f1)   $(cat "$DMG.sha256" | cut -d' ' -f1)"
echo

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  cat <<'EOF'
Signed with a real identity, so you can notarise it — which removes the
right-click-to-open step for everyone else:

    xcrun notarytool submit "<the .dmg>" --keychain-profile "<profile>" --wait
    xcrun stapler staple "<the .dmg>"

Set the profile up once with:
    xcrun notarytool store-credentials "<profile>" \
      --apple-id "<you@example.com>" --team-id "<TEAMID>"

A real identity is also what stops the Accessibility grant being revoked by
every rebuild, since the signature then stays the same.
EOF
fi
