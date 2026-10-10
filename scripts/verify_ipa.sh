#!/usr/bin/env bash
# Verify that an IPA has the layout ESign / sideloading tools expect:
#   Payload/<AppName>.app/...  (exactly one top-level .app, no nesting, non-empty, right bundle id)
# Usage: verify_ipa.sh <ipa> <expected-bundle-id> <app-name> [required-appex-name ...]
set -euo pipefail

IPA="$1"
EXPECTED_ID="$2"
APP_NAME="$3"
shift 3
REQUIRED_APPEX=("$@")

fail() { echo "::error::IPA check failed: $*"; exit 1; }

[ -f "$IPA" ] || fail "file not found: $IPA"
SIZE=$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")
[ "$SIZE" -gt 10000 ] || fail "IPA is suspiciously small ($SIZE bytes)"

ENTRIES=$(zipinfo -1 "$IPA")
[ -n "$ENTRIES" ] || fail "IPA is empty"

# 1. Every entry must live under Payload/
BAD=$(echo "$ENTRIES" | grep -v '^Payload/' || true)
[ -z "$BAD" ] || fail "entries outside Payload/: $(echo "$BAD" | head -5 | tr '\n' ' ')"

# 2. Exactly one top-level .app, and it is <AppName>.app
TOP_APPS=$(echo "$ENTRIES" | sed -n 's#^Payload/\([^/]*\.app\)/.*#\1#p' | sort -u)
[ "$(echo "$TOP_APPS" | grep -c . || true)" -eq 1 ] || fail "expected exactly one top-level .app, found: $TOP_APPS"
[ "$TOP_APPS" = "$APP_NAME.app" ] || fail "top-level app is '$TOP_APPS', expected '$APP_NAME.app'"

# 3. No nested .app bundles (app extensions are .appex and are allowed under PlugIns/)
if echo "$ENTRIES" | grep -Eq '^Payload/[^/]+\.app/.+\.app/'; then
  fail "nested .app bundle found"
fi

# 4. No stray project files
if echo "$ENTRIES" | grep -Eq '\.(xcodeproj|xcworkspace|swift)(/|$)'; then
  fail "source/project files found inside IPA"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/$APP_NAME.app"
PLIST="$APP/Info.plist"
[ -f "$PLIST" ] || fail "Info.plist missing"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST" 2>/dev/null || echo "?")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")

[ "$BUNDLE_ID" = "$EXPECTED_ID" ] || fail "bundle id is '$BUNDLE_ID', expected '$EXPECTED_ID'"
[ -f "$APP/$EXECUTABLE" ] || fail "executable '$EXECUTABLE' missing"
file "$APP/$EXECUTABLE" | grep -q 'Mach-O 64-bit executable arm64' || fail "executable is not an arm64 Mach-O: $(file "$APP/$EXECUTABLE")"

for EXT in "${REQUIRED_APPEX[@]+"${REQUIRED_APPEX[@]}"}"; do
  EXT_DIR="$APP/PlugIns/$EXT.appex"
  [ -d "$EXT_DIR" ] || fail "app extension $EXT.appex missing from PlugIns/"
  EXT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$EXT_DIR/Info.plist")
  case "$EXT_ID" in
    "$EXPECTED_ID".*) ;;
    *) fail "extension bundle id '$EXT_ID' is not prefixed by '$EXPECTED_ID.'" ;;
  esac
  echo "  extension:   $EXT.appex ($EXT_ID)"
done

if codesign -dv "$APP" >/dev/null 2>&1; then
  SIGNED="signed (unexpected for this build)"
else
  SIGNED="unsigned (expected: sign with ESign before installing)"
fi

echo "IPA OK"
echo "  file:        $IPA ($SIZE bytes)"
echo "  app:         Payload/$APP_NAME.app"
echo "  bundle id:   $BUNDLE_ID"
echo "  version:     $VERSION"
echo "  minimum iOS: $MIN_OS"
echo "  executable:  $EXECUTABLE ($(file -b "$APP/$EXECUTABLE"))"
echo "  signature:   $SIGNED"
echo "  plugins:     $(ls "$APP/PlugIns" 2>/dev/null | tr '\n' ' ' || true)"
