#!/usr/bin/env bash
# ---------------------------------------------
# release.sh — Sparkle appcast tool (macOS-safe, self-healing, dedupe builds)
# Compatible with /bin/bash 3.2.57 on macOS 18+
# ---------------------------------------------

# If not running under bash, re-exec with bash (prevents weird parse errors)
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

# --------- EDIT THESE CONSTANTS ---------
APP_NAME="Photos Export GPS Fixer"
REPO_DOCS="$HOME/Documents/git-repo-2025/myapps/myapps/docs"
SPARKLE_BIN="$HOME/Developer/Sparkle/bin"
BASE_URL="https://rphoto.github.io/myapps"
MIN_SYSTEM_VERSION="16.0"
NOTES_TEMPLATE=""
# ---------------------------------------

# ---- normalize base URL (avoid // in links) ----
BASE_URL="${BASE_URL%/}"

# ---- add Sparkle binaries to PATH ----
export PATH="$SPARKLE_BIN:$PATH"

# ---- argument checks ----
if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/ExportedApp.app" >&2
  exit 1
fi

APP_PATH="$1"

# More specific error checking
if [ ! -e "$APP_PATH" ]; then
  echo "Error: File does not exist: $APP_PATH" >&2
  echo "Hint: Check the filename and path. Use quotes around paths with spaces." >&2
  DIR_PATH=$(dirname "$APP_PATH")
  BASENAME=$(basename "$APP_PATH" .app)
  if [ -d "$DIR_PATH" ]; then
    echo "Similar .app files in $(dirname "$APP_PATH"):" >&2
    find "$DIR_PATH" -maxdepth 1 -name "*.app" -type d 2>/dev/null | head -5 >&2 || true
  fi
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: Path exists but is not a directory: $APP_PATH" >&2
  echo "Hint: .app bundles should be directories, not regular files." >&2
  exit 1
fi

if [ "${APP_PATH##*.}" != "app" ]; then
  echo "Error: Path does not end with .app extension: $APP_PATH" >&2
  echo "Hint: Provide a path to a .app bundle." >&2
  exit 1
fi

if [ ! -r "$APP_PATH" ]; then
  echo "Error: Cannot read .app bundle: $APP_PATH" >&2
  echo "Hint: Check file permissions." >&2
  exit 1
fi

# ---- Sparkle binary checks ----
if [ ! -d "$SPARKLE_BIN" ]; then
  echo "Error: Sparkle bin directory does not exist: $SPARKLE_BIN" >&2
  echo "Hint: Make sure Sparkle is installed and SPARKLE_BIN path is correct." >&2
  exit 1
fi

if [ ! -f "$SPARKLE_BIN/sign_update" ]; then
  echo "Error: sign_update binary not found at: $SPARKLE_BIN/sign_update" >&2
  echo "Hint: Make sure Sparkle is properly installed with all binaries." >&2
  if [ -d "$SPARKLE_BIN" ]; then
    echo "Available files in $SPARKLE_BIN:" >&2
    ls -la "$SPARKLE_BIN" 2>/dev/null >&2 || echo "  (cannot list directory)" >&2
  fi
  exit 1
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "Error: sign_update binary exists but is not executable: $SPARKLE_BIN/sign_update" >&2
  echo "Hint: Fix permissions with: chmod +x '$SPARKLE_BIN/sign_update'" >&2
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

# ---- Create a temp dir early so we can safely write files into it ----
TMP_DIR=$(mktemp -d -t release_sh_tmp.XXXXXX)
cleanup() { [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---- release notes (cumulative, grouped by version, newest→oldest; idempotent) ----
NOTES_FILE="$NOTES_DIR/$SHORT_VERSION.html"

# 1) Create or template the base note for the *current* version
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

# Helper: extract single-line <li>…</li> from a file (current version list)
extract_lis() {
  grep -oE '<li[^>]*>.*</li>' "$1" 2>/dev/null || true
}

# Helper: extract only the "What's new" list items from an older file
# This ensures idempotency (we don't re-harvest already aggregated history).
extract_whatsnew_lis() {
  local file="$1"
  awk '
    BEGIN{inblock=0}
    # Match h2 tags containing What and new with optional apostrophe
    /<h2[^>]*>.*What.?s[[:space:]]+new.*<\/h2>/ {inblock=1; next}
    inblock {
      print
      if ($0 ~ /<\/ul>/) exit
    }
  ' "$file" | grep -oE '<li[^>]*>.*</li>' || true
}

# Helper: convert version string to sortable format
version_to_sortable() {
  local ver="$1"
  # Convert "2.9.3" to "00002.00009.00003" for proper sorting
  echo "$ver" | awk -F. '{
    for(i=1; i<=NF; i++) {
      if(i>1) printf "."
      printf "%05d", $i
    }
    # Pad with zeros if fewer than 3 parts
    for(i=NF+1; i<=3; i++) {
      printf ".00000"
    }
    printf "\n"
  }'
}

# 2) Gather current version items
CURRENT_LIS="$(extract_lis "$NOTES_FILE")"

# 3) Gather previous versions' items (sorted newest → oldest by version number)
PREV_GROUPED_HTML=""
if ls -1 "$NOTES_DIR"/*.html >/dev/null 2>&1; then
  tmp_versions="$TMP_DIR/versions.txt"
  tmp_grouped="$TMP_DIR/prev_grouped.html"
  : > "$tmp_grouped"
  : > "$tmp_versions"

  # Get all version files except current one
  for notes_file in "$NOTES_DIR"/*.html; do
    [ ! -f "$notes_file" ] && continue
    ver=$(basename "$notes_file" .html)
    [ "$ver" = "$SHORT_VERSION" ] && continue
    
    # Create sortable version and store with original
    sortable=$(version_to_sortable "$ver")
    echo "$sortable $ver" >> "$tmp_versions"
  done

  # Sort by version (newest first) and process - avoid subshell by using temp file
  if [ -s "$tmp_versions" ]; then
    tmp_sorted="$TMP_DIR/sorted_versions.txt"
    sort -r "$tmp_versions" > "$tmp_sorted"
    
    while IFS=' ' read -r sortable_ver ver || [ -n "$ver" ]; do
      [ -z "$ver" ] && continue
      f="$NOTES_DIR/$ver.html"
      [ ! -f "$f" ] && continue
      
      lis="$(extract_whatsnew_lis "$f")"
      
      # If no "What's new" section found, try to extract all <li> items
      if [ -z "$lis" ]; then
        lis="$(extract_lis "$f")"
      fi
      
      [ -z "$lis" ] && continue
      
      {
        printf '  <li><strong>v%s</strong>\n' "$ver"
        printf '    <ul>\n'
        printf '%s\n' "$lis"
        printf '    </ul>\n'
        printf '  </li>\n'
      } >> "$tmp_grouped"
    done < "$tmp_sorted"

    if [ -s "$tmp_grouped" ]; then
      PREV_GROUPED_HTML="$(cat "$tmp_grouped")"
    fi
  fi
fi

# 4) Rebuild current notes to include the grouped, cumulative history
COMBINED_NOTES="$TMP_DIR/notes_${SHORT_VERSION}.html"

{
  printf '%s\n' '<!doctype html><meta charset="utf-8">'
  printf '<title>%s %s</title>\n' "$APP_NAME" "$SHORT_VERSION"
  printf '<h1>%s %s</h1>\n' "$APP_NAME" "$SHORT_VERSION"

  # Current version section (What's new)
  printf '%s\n' '<h2>What'"'"'s new</h2>'
  printf '%s\n' '<ul>'
  if [ -n "$CURRENT_LIS" ]; then
    printf '%s\n' "$CURRENT_LIS"
  else
    printf '%s\n' '  <li>Improvements and bug fixes.</li>'
  fi
  printf '%s\n' '</ul>'

  # Previous versions section, grouped by version (only if we found any)
  if [ -n "$PREV_GROUPED_HTML" ]; then
    printf '%s\n' '<h2>Previous versions</h2>'
    printf '%s\n' '<ul class="versions">'
    printf '%s\n' "$PREV_GROUPED_HTML"
    printf '%s\n' '</ul>'
  fi
} > "$COMBINED_NOTES"

mv "$COMBINED_NOTES" "$NOTES_FILE"

# ---- URLs ----
ZIP_URL="$BASE_URL/releases/$ZIP_NAME"
NOTES_URL="$BASE_URL/notes/$SHORT_VERSION.html"
APPCAST_URL="$BASE_URL/appcast.xml"

# ---- new appcast item (write to file to avoid $(...) pitfalls) ----
PUBDATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S %z")

NEW_ITEM_FILE="$TMP_DIR/new_item.xml"
cat > "$NEW_ITEM_FILE" <<EOF
    <item>
      <title>Version $SHORT_VERSION</title>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>
      <enclosure
        url="$ZIP_URL"
        sparkle:edSignature="$SIG"
        length="$LEN"
        type="application/octet-stream"/>
    </item>
EOF

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

# ---- self-heal: header first, normalize URLs, remove duplicates ----
# Dedup logic:
#  - PRIMARY key: shortVersion + "|" + buildVersion (drop duplicate builds; keep newest/first)
#  - SECONDARY key: enclosure URL (drop exact file duplicates)
#  - Legacy double-slash URLs normalized
repair_appcast_structure() {
  [ ! -f "$APPCAST" ] && return 0

  local tmp_items="$TMP_DIR/items.xml"
  local tmp_new="$TMP_DIR/new_appcast.xml"
  local bad="${BASE_URL}//"
  local good="${BASE_URL}/"

  awk -v bad="$bad" -v good="$good" '
    BEGIN { initem = 0; buf = "" }
    function trim(s){ sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function extract_tag(body, tag,   pos, val, open, after, endpos) {
      open = "<" tag ">"
      pos = index(body, open)
      if (pos == 0) return ""
      after = substr(body, pos + length(open))
      endpos = index(after, "<")
      if (endpos == 0) return ""
      val = substr(after, 1, endpos - 1)
      return trim(val)
    }
    function extract_attr(body, attr,   pos, after, q1, val) {
      pos = index(body, attr "=\"")
      if (pos == 0) return ""
      after = substr(body, pos + length(attr) + 2)
      q1 = index(after, "\"")
      if (q1 == 0) return ""
      val = substr(after, 1, q1 - 1)
      return val
    }
    function flush_item() {
      if (buf == "") return
      b = buf
      gsub(bad, good, b)

      sv = extract_tag(b, "sparkle:shortVersionString")
      bv = extract_tag(b, "sparkle:version")
      url = extract_attr(b, "url")

      key = sv "|" bv

      if (url != "" && (url in seenUrl)) {
        buf = ""; return
      }
      if (sv != "" && bv != "" && (key in seenKey)) {
        buf = ""; return
      }

      if (url != "") seenUrl[url] = 1
      if (sv != "" && bv != "") seenKey[key] = 1
      print b
      buf = ""
    }
    /<item>/ { initem = 1; buf = $0; next }
    initem {
      buf = buf ORS $0
      if ($0 ~ /<\/item>/) { flush_item(); initem = 0 }
      next
    }
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
  echo "• Repaired appcast: metadata first, URLs normalized, duplicate builds & files removed"
}

# ---- remove any existing item for this version / URL (fresh publish) ----
remove_existing_version_item() {
  local tmp="$TMP_DIR/appcast_wo_version.xml"
  awk -v ver="$SHORT_VERSION" -v zip="$ZIP_URL" '
    BEGIN { initem = 0; buf = "" }
    function flush_item() {
      if (buf == "") return
      keep = 1
      # Drop the item if it matches this short version OR exactly this ZIP url
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
  local tmp="$TMP_DIR/appcast_updated.xml"
  awk -v file="$NEW_ITEM_FILE" '
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
repair_appcast_structure         # includes duplicate build removal
remove_existing_version_item     # remove current version (if present)
insert_item_after_language       # insert the fresh item

echo "✅ Done"
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $NOTES_FILE"
echo "  $APPCAST"