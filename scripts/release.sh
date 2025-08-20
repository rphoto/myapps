#!/usr/bin/env bash
# ---------------------------------------------
# release.sh — keychain-based Sparkle appcast tool
# ---------------------------------------------
set -euo pipefail

# --------- EDIT THESE CONSTANTS ---------
APP_NAME="Photos Export GPS Fixer"
REPO_DOCS="$HOME/Documents/git-repo-2025/myapps/myapps/docs"
SPARKLE_BIN="$HOME/Documents/git-repo-2025/myapps/myapps/Sparkle/bin"
BASE_URL="https://rphoto.github.io/myapps"
MIN_SYSTEM_VERSION="16.0"
NOTES_TEMPLATE=""
# ---------------------------------------

# ---- add Sparkle binaries to PATH ----
export PATH="$SPARKLE_BIN:$PATH"

# ---- argument checks ----
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/ExportedApp.app"
  exit 1
fi
APP_PATH="$1"
if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Error: argument must be a .app bundle"
  exit 1
fi
if [[ ! -f "$SPARKLE_BIN/sign_update" ]]; then
  echo "Error: sign_update not found at $SPARKLE_BIN/sign_update"
  exit 1
fi

# ---- directories ----
RELEASES_DIR="$REPO_DOCS/releases"
NOTES_DIR="$REPO_DOCS/notes"
APPCAST="$REPO_DOCS/appcast.xml"
mkdir -p "$RELEASES_DIR" "$NOTES_DIR"

INFO_PLIST="$APP_PATH/Contents/Info.plist"

# ---- extract version info ----
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
if [[ -z "$SHORT_VERSION" || -z "$BUILD_VERSION" ]]; then
  echo "Error: unable to read version info from Info.plist"
  exit 1
fi

# ---- filenames & paths ----
SAFE_NAME=$(echo "$APP_NAME" | tr -cd '[:alnum:]._-')
ZIP_NAME="${SAFE_NAME}-${SHORT_VERSION}.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"

# ---- create zip ----
echo "• Zipping $APP_NAME $SHORT_VERSION → $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ZIP_SIZE=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH")

# ---- sign zip (FIXED PARSING) ----
echo "• Signing zip with Sparkle key from keychain"
SIGN_OUTPUT=$(sign_update "$ZIP_PATH")
echo "• Sign output: $SIGN_OUTPUT"  # Debug line - remove later

# Parse the correct format: sparkle:edSignature="..." length="..."
SIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

# Fallback to ZIP size if length not found
[[ -z "$LEN" ]] && LEN="$ZIP_SIZE"

if [[ -z "$SIG" ]]; then
  echo "Error: could not parse signature from sign_update output:"
  echo "$SIGN_OUTPUT"
  exit 1
fi

echo "• Signature: $SIG"
echo "• Length: $LEN"

# ---- release notes ----
NOTES_FILE="$NOTES_DIR/$SHORT_VERSION.html"
if [[ -n "$NOTES_TEMPLATE" && -f "$NOTES_TEMPLATE" ]]; then
  sed -e "s/{{VERSION}}/$SHORT_VERSION/g" \
      -e "s/{{BUILD}}/$BUILD_VERSION/g"  \
      "$NOTES_TEMPLATE" > "$NOTES_FILE"
else
cat > "$NOTES_FILE" <<EOF
<!doctype html><meta charset="utf-8">
<title>$APP_NAME $SHORT_VERSION</title>
<h1>$APP_NAME $SHORT_VERSION</h1>
<ul>
  <li>Improvements and bug fixes.</li>
</ul>
EOF
fi

# ---- URLs ----
ZIP_URL="$BASE_URL/releases/$ZIP_NAME"
NOTES_URL="$BASE_URL/notes/$SHORT_VERSION.html"
APPCAST_URL="$BASE_URL/appcast.xml"

# ---- new appcast item ----
PUBDATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S %z")

# Use printf instead of read -d to avoid issues with heredoc
NEW_ITEM=$(printf '%s\n' \
"    <item>" \
"      <title>Version $SHORT_VERSION</title>" \
"      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>" \
"      <sparkle:version>$BUILD_VERSION</sparkle:version>" \
"      <pubDate>$PUBDATE</pubDate>" \
"      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>" \
"      <sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>" \
"      <enclosure" \
"        url=\"$ZIP_URL\"" \
"        sparkle:edSignature=\"$SIG\"" \
"        length=\"$LEN\"" \
"        type=\"application/octet-stream\"/>" \
"    </item>")

# ---- create or update appcast ----
if [[ ! -f "$APPCAST" ]]; then
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$APPCAST_URL</link>
    <description>Release notes and downloads</description>
    <language>en</language>

$NEW_ITEM

  </channel>
</rss>
EOF
  echo "• Created new appcast.xml"
else
  TMP="${APPCAST}.tmp"
  # FIXED: Replace AWK with sed to avoid newline parsing issues
  # Write NEW_ITEM to temporary file first
  echo "$NEW_ITEM" > "${TMP}.newitem"
  
  # Insert after <channel> line and add blank line
  sed '/^  <channel>/r '"${TMP}.newitem" "$APPCAST" | \
  sed '/^  <channel>/{
    a\

  }' > "$TMP"
  
  # Clean up temporary file
  rm -f "${TMP}.newitem"
  mv "$TMP" "$APPCAST"
  echo "• Updated existing appcast.xml"
fi

echo "✓ Done"
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $NOTES_FILE"
echo "  $APPCAST"
