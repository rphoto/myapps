#!/usr/bin/env bash
# ---------------------------------------------
# release.sh — keychain-based Sparkle appcast tool (macOS-safe, self-healing)
# Compatible with /bin/bash 3.2.57 on macOS 18+
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

# ---- normalize base URL (avoid // in links) ----
# Works in bash 3.2
BASE_URL="${BASE_URL%/}"

# ---- add Sparkle binaries to PATH ----
export PATH="$SPARKLE_BIN:$PATH"

# ---- argument checks ----
if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/ExportedApp.app" >&2
  exit 1
fi
APP_PATH="$1"
if [ ! -d "$APP_PATH" ] || [ "${APP_PATH##*.}" != "app" ]; then
  echo "Error: argument must be a .app bundle" >&2
  exit 1
fi
if [ ! -f "$SPARKLE_BIN/sign_update" ]; then
  echo "Error: sign_update not found at $SPARKLE_BIN/sign_update" >&2
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
if [ -z "${SHORT_VERSION:-}" ] || [ -z "${BUILD_VERSION:-}" ]; then
  echo "Error: unable to read version info from Info.plist" >&2
  exit 1
fi

# ---- filenames & paths ----
SAFE_NAME=$(printf "%s" "$APP_NAME" | tr -cd '[:alnum:]._-')
ZIP_NAME="${SAFE_NAME}-${SHORT_VERSION}.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"

# ---- create zip ----
echo "• Zipping $APP_NAME $SHORT_VERSION → $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
# stat on macOS uses -f%z
ZIP_SIZE=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH")

# ---- sign zip ----
echo "• Signing zip with Sparkle key from keychain"
SIGN_OUTPUT=$(sign_update "$ZIP_PATH")
# echo "• Sign output: $SIGN_OUTPUT"  # uncomment to debug

# Parse Sparkle 2 signature fields (BSD sed-friendly)
SIG=$(printf "%s\n" "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(printf "%s\n" "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -z "${LEN:-}" ] && LEN="$ZIP_SIZE"

if [ -z "${SIG:-}" ]; then
  echo "Error: could not parse signature from sign_update output:" >&2
  echo "$SIGN_OUTPUT" >&2
  exit 1
fi

echo "• Signature: $SIG"
echo "• Length: $LEN"

# ---- release notes ----
NOTES_FILE="$NOTES_DIR/$SHORT_VERSION.html"
if [ -n "$NOTES_TEMPLATE" ] && [ -f "$NOTES_TEMPLATE" ]; then
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
# macOS date(1) supports %z
PUBDATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S %z")

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

# ---- temp area (portable) ----
TMP_DIR=$(mktemp -d -t release_sh_tmp.XXXXXX)
cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# ---- ensure appcast exists ----
ensure_appcast_exists() {
  if [ ! -f "$APPCAST" ]; then
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

  </channel>
</rss>
EOF
    echo "• Created new appcast.xml"
  fi
}

# ---- self-heal: rebuild appcast with proper header, normalize URLs, dedupe ----
repair_appcast_structure() {
  [ ! -f "$APPCAST" ] && return 0

  local tmp_items="$TMP_DIR/items.xml"
  local tmp_new="$TMP_DIR/new_appcast.xml"
  local bad="${BASE_URL}//"
  local good="${BASE_URL}/"

  # Extract <item> blocks, normalize // paths, and dedupe by shortVersion (keep first)
  # BSD awk-friendly (no regex in function bodies)
  awk -v bad="$bad" -v good="$good" '
    BEGIN { initem = 0; buf = "" }
    function flush_item() {
      if (buf == "") return
      b = buf
      gsub(bad, good, b) # normalize URLs

      # Pull <sparkle:shortVersionString>value<
      tag = "<sparkle:shortVersionString>"
      s = index(b, tag)
      ver = ""
      if (s > 0) {
        s2 = s + length(tag)
        rest = substr(b, s2)
        e = index(rest, "<")
        if (e > 0) ver = substr(rest, 1, e - 1)
      }

      if (ver != "") {
        if (!(ver in seen)) { print b; seen[ver] = 1 }
      } else {
        print b
      }
      buf = ""
    }
    /<item>/ { initem = 1; buf = $0; next }
    initem {
      buf = buf ORS $0
      if ($0 ~ /<\/item>/) { flush_item(); initem = 0 }
      next
    }
    END { flush_item() }
  ' "$APPCAST" > "$tmp_items"

  # Rebuild appcast with header first, then items
  cat > "$tmp_new" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$APPCAST_URL</link>
    <description>Release notes and downloads</description>
    <language>en</language>

EOF

  cat "$tmp_items" >> "$tmp_new"

  cat >> "$tmp_new" <<'EOF'

  </channel>
</rss>
EOF

  mv "$tmp_new" "$APPCAST"
  echo "• Repaired appcast structure (metadata first, URLs normalized, duplicates removed)"
}

# ---- remove any existing item for this version / URL ----
remove_existing_version_item() {
  local tmp="$TMP_DIR/appcast_wo_version.xml"
  awk -v ver="$SHORT_VERSION" -v zip="$ZIP_URL" '
    BEGIN { initem = 0; buf = "" }
    function flush_item() {
      if (buf == "") return
      keep = 1
      if (index(buf, "<sparkle:shortVersionString>" ver "<") > 0) keep = 0
      if (index(buf, zip) > 0) keep = 0
      if (keep) print buf
      buf = ""
    }
    /<item>/ { initem = 1; buf = $0; next }
    initem {
      buf = buf ORS $0
      if ($0 ~ /<\/item>/) { flush_item(); initem = 0 }
      next
    }
    { if (!initem) print }
    END { flush_item() }
  ' "$APPCAST" > "$tmp"
  mv "$tmp" "$APPCAST"
}

# ---- insert new item after <language> ----
insert_item_after_language() {
  local newitem_file="$TMP_DIR/new_item.xml"
  printf '%s\n' "$NEW_ITEM" > "$newitem_file"

  local tmp="$TMP_DIR/appcast_updated.xml"
  awk -v file="$newitem_file" '
    BEGIN { inserted = 0 }
    {
      print
      if (!inserted && index($0, "<language>") > 0) {
        while ((getline line < file) > 0) print line
        close(file)
        inserted = 1
      }
    }
  ' "$APPCAST" > "$tmp"
  mv "$tmp" "$APPCAST"
}

# ---- run steps ----
ensure_appcast_exists
repair_appcast_structure
remove_existing_version_item
insert_item_after_language

echo "✓ Done"
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $NOTES_FILE"
echo "  $APPCAST"