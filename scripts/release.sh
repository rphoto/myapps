#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# release-unified.sh — Sparkle release/appcast tool for multiple apps
# Compatible with /bin/bash 3.2.x on macOS
#
# Usage:
#   scripts/release-unified.sh <app-key> /path/to/ExportedApp.app
#
# Examples:
#   scripts/release-unified.sh macoutdated ~/Downloads/MacOutdated-1.38.app
#   scripts/release-unified.sh photos-export-gps-fixer ~/Downloads/Photos\ Export\ GPS\ Fixer-2.1.app
#
# To add a new app later, add one more register_app line in the APP CONFIG section
# and put its docs under docs/<app-key>/ unless it is a legacy root-docs app.
# -----------------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      break
      ;;
  esac
done

run_cmd() {
  if $DRY_RUN; then
    printf '[DRY-RUN] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DOCS_ROOT="$REPO_ROOT/docs"
SPARKLE_BIN_DEFAULT="$HOME/Developer/Sparkle/bin"
SPARKLE_BIN="${SPARKLE_BIN:-$SPARKLE_BIN_DEFAULT}"
NOTES_TEMPLATE=""

# ---- app registry -----------------------------------------------------------
# Format:
#   key|display name|docs relative path|base URL|minimum system version|appcast filename
#
# docs relative path examples:
#   macoutdated               -> docs/macoutdated
#   .                         -> docs/                (legacy root-docs app)
#   newapp                    -> docs/newapp
#
# To add a new app, copy one line and edit the fields.
APP_CONFIGS=""
register_app() {
  APP_CONFIGS="${APP_CONFIGS}$1
"
}

register_app "macoutdated|MacOutdated|macoutdated|https://rphoto.github.io/myapps/macoutdated|15.6|appcast-macoutdated.xml"
register_app "photos-export-gps-fixer|Photos Export GPS Fixer|.|https://rphoto.github.io/myapps|16.0|appcast.xml"

# Example future app:
# register_app "newapp|NewApp|newapp|https://rphoto.github.io/myapps/newapp|16.0|appcast.xml"

usage() {
  cat >&2 <<USAGE
Usage:
  $0 [--dry-run] <app-key> /path/to/ExportedApp.app

Known app keys:
$(list_app_keys | sed 's/^/  - /')
USAGE
  exit 1
}

list_app_keys() {
  printf '%s' "$APP_CONFIGS" | awk -F'|' 'NF >= 1 && $1 != "" { print $1 }'
}

load_app_config() {
  local wanted_key="$1"
  local line
  line=$(printf '%s' "$APP_CONFIGS" | awk -F'|' -v key="$wanted_key" 'NF >= 6 && $1 == key { print; exit }')

  if [ -z "$line" ]; then
    echo "Error: unknown app key: $wanted_key" >&2
    echo "Known app keys:" >&2
    list_app_keys | sed 's/^/  - /' >&2
    exit 1
  fi

  APP_KEY=$(printf '%s' "$line" | awk -F'|' '{print $1}')
  APP_NAME=$(printf '%s' "$line" | awk -F'|' '{print $2}')
  DOCS_REL=$(printf '%s' "$line" | awk -F'|' '{print $3}')
  BASE_URL=$(printf '%s' "$line" | awk -F'|' '{print $4}')
  MIN_SYSTEM_VERSION=$(printf '%s' "$line" | awk -F'|' '{print $5}')
  APPCAST_FILE=$(printf '%s' "$line" | awk -F'|' '{print $6}')

  if [ "$DOCS_REL" = "." ]; then
    REPO_DOCS="$DOCS_ROOT"
  else
    REPO_DOCS="$DOCS_ROOT/$DOCS_REL"
  fi

  RELEASES_DIR="$REPO_DOCS/releases"
  NOTES_DIR="$REPO_DOCS/notes"
  APPCAST="$REPO_DOCS/$APPCAST_FILE"
  BASE_URL="${BASE_URL%/}"
}

# ---- argument checks --------------------------------------------------------
if $DRY_RUN; then
  echo "⚠️  DRY RUN MODE — no changes will be made"
  echo ""
fi

if [ $# -ne 2 ]; then
  usage
fi

APP_KEY="$1"
APP_PATH="$2"
load_app_config "$APP_KEY"

export PATH="$SPARKLE_BIN:$PATH"

if [ ! -e "$APP_PATH" ]; then
  echo "Error: file does not exist: $APP_PATH" >&2
  echo "Hint: check the filename and path. Use quotes around paths with spaces." >&2
  DIR_PATH=$(dirname "$APP_PATH")
  if [ -d "$DIR_PATH" ]; then
    echo "Similar .app files in $DIR_PATH:" >&2
    find "$DIR_PATH" -maxdepth 1 -name "*.app" -type d 2>/dev/null | head -5 >&2 || true
  fi
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: path exists but is not a directory: $APP_PATH" >&2
  echo "Hint: .app bundles should be directories, not regular files." >&2
  exit 1
fi

if [ "${APP_PATH##*.}" != "app" ]; then
  echo "Error: path does not end with .app extension: $APP_PATH" >&2
  echo "Hint: provide a path to a .app bundle." >&2
  exit 1
fi

if [ ! -r "$APP_PATH" ]; then
  echo "Error: cannot read .app bundle: $APP_PATH" >&2
  echo "Hint: check file permissions." >&2
  exit 1
fi

if [ ! -d "$SPARKLE_BIN" ]; then
  echo "Error: Sparkle bin directory does not exist: $SPARKLE_BIN" >&2
  echo "Hint: set SPARKLE_BIN or fix the default path." >&2
  exit 1
fi

if [ ! -f "$SPARKLE_BIN/sign_update" ]; then
  echo "Error: sign_update binary not found at: $SPARKLE_BIN/sign_update" >&2
  echo "Hint: make sure Sparkle is installed with all binaries." >&2
  if [ -d "$SPARKLE_BIN" ]; then
    echo "Available files in $SPARKLE_BIN:" >&2
    ls -la "$SPARKLE_BIN" >&2 || true
  fi
  exit 1
fi

if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "Error: sign_update binary exists but is not executable: $SPARKLE_BIN/sign_update" >&2
  echo "Hint: chmod +x '$SPARKLE_BIN/sign_update'" >&2
  exit 1
fi

run_cmd mkdir -p "$RELEASES_DIR" "$NOTES_DIR"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "Error: missing Info.plist: $INFO_PLIST" >&2
  exit 1
fi

SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
if [ -z "${SHORT_VERSION:-}" ] || [ -z "${BUILD_VERSION:-}" ]; then
  echo "Error: unable to read version info from Info.plist" >&2
  exit 1
fi

# ---- release notes collection ----------------------------------------------
RELEASE_NOTES_LIS=""
echo ""
echo "📝 Release notes for $APP_NAME $SHORT_VERSION (build $BUILD_VERSION)"
echo "   Enter each change item and press Return."
echo "   Enter a blank line when done (at least one item required)."
echo ""
_item_count=0
while true; do
  printf "  Item %d: " "$((_item_count + 1))"
  IFS= read -r _item < /dev/tty
  if [ -z "$_item" ]; then
    if [ "$_item_count" -eq 0 ]; then
      echo "  ⚠️  At least one item is required. Please enter a release note."
      continue
    fi
    break
  fi
  _item_escaped=$(printf '%s' "$_item" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  RELEASE_NOTES_LIS="${RELEASE_NOTES_LIS}<li>${_item_escaped}</li>
"
  _item_count=$((_item_count + 1))
done

echo ""
echo "  ✓ $APP_NAME $SHORT_VERSION — $_item_count item(s) recorded."
echo ""

# ---- filenames & paths ------------------------------------------------------
SAFE_NAME=$(printf '%s' "$APP_NAME" | tr -cd '[:alnum:]._-')
ZIP_NAME="${SAFE_NAME}-${SHORT_VERSION}.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
NOTES_FILE="$NOTES_DIR/$SHORT_VERSION.html"

# ---- zip and sign -----------------------------------------------------------
echo "• Zipping $APP_NAME $SHORT_VERSION → $ZIP_PATH"
if $DRY_RUN; then
  run_cmd rm -f "$ZIP_PATH"
  run_cmd ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  ZIP_SIZE=0
else
  run_cmd rm -f "$ZIP_PATH"
  run_cmd ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  ZIP_SIZE=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH")
fi

echo "• Signing zip with Sparkle key from keychain"
if $DRY_RUN; then
  run_cmd sign_update "$ZIP_PATH"
  SIGN_OUTPUT='sparkle:edSignature="DRY_RUN_SIGNATURE" length="0"'
else
  SIGN_OUTPUT=$(sign_update "$ZIP_PATH")
fi
SIG=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LEN=$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -z "${LEN:-}" ] && LEN="$ZIP_SIZE"

if [ -z "${SIG:-}" ]; then
  echo "Error: could not parse signature from sign_update output:" >&2
  echo "$SIGN_OUTPUT" >&2
  exit 1
fi

echo "• Signature: $SIG"
echo "• Length: $LEN"

# ---- dry-run summary --------------------------------------------------------
if $DRY_RUN; then
  ZIP_URL="$BASE_URL/releases/$ZIP_NAME"
  NOTES_URL="$BASE_URL/notes/$SHORT_VERSION.html"
  APPCAST_URL="$BASE_URL/$APPCAST_FILE"
  COMMIT_MSG="Release $APP_NAME $SHORT_VERSION (build $BUILD_VERSION)"

  echo ""
  echo "• Would write release notes:"
  echo "  $NOTES_FILE"
  echo "• Would update appcast:"
  echo "  $APPCAST"
  echo "  (release notes URL: $NOTES_URL)"
  echo "  (zip URL: $ZIP_URL)"
  echo "• Would create/update artifacts:"
  echo "  $ZIP_PATH"
  echo "  $NOTES_FILE"
  echo "  $APPCAST"

  echo ""
  echo "• Would stage files for git commit…"
  GIT_ROOT=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "${GIT_ROOT:-}" ]; then
    run_cmd git -C "$GIT_ROOT" add "$ZIP_PATH" "$NOTES_FILE" "$APPCAST"
    run_cmd git -C "$GIT_ROOT" commit -m "$COMMIT_MSG"
  else
    echo "⚠️  Warning: $REPO_ROOT is not inside a git repository — would skip git commit."
  fi

  echo ""
  echo "✅ Dry run complete"
  exit 0
fi

TMP_DIR=$(mktemp -d -t release_unified_tmp.XXXXXX)
cleanup() { [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---- release notes generation ----------------------------------------------
extract_lis() {
  grep -oE '<li[^>]*>.*</li>' "$1" 2>/dev/null || true
}

extract_whatsnew_lis() {
  local file="$1"
  awk '
    BEGIN { inblock = 0 }
    /[<]h2[^>]*>[^<]*What.?s[[:space:]]+new[^<]*<\/h2>/ { inblock = 1; next }
    inblock {
      print
      if ($0 ~ /<\/ul>/) exit
    }
  ' "$file" | grep -oE '<li[^>]*>.*</li>' || true
}

version_to_sortable() {
  local ver="$1"
  echo "$ver" | awk -F. '{
    for (i = 1; i <= NF; i++) {
      if (i > 1) printf "."
      printf "%05d", $i
    }
    for (i = NF + 1; i <= 3; i++) {
      printf ".00000"
    }
    printf "\n"
  }'
}

if [ -n "$NOTES_TEMPLATE" ] && [ -f "$NOTES_TEMPLATE" ]; then
  sed -e "s/{{VERSION}}/$SHORT_VERSION/g" \
      -e "s/{{BUILD}}/$BUILD_VERSION/g" \
      "$NOTES_TEMPLATE" > "$NOTES_FILE"
else
  {
    printf '%s\n' '<!DOCTYPE html>'
    printf '%s %s%s\n' '<html><head><meta charset="UTF-8"><title>' "$APP_NAME $SHORT_VERSION" '</title></head><body>'
    printf '%s %s%s\n' '<h1>' "$APP_NAME $SHORT_VERSION" '</h1>'
    printf '%s\n' '<ul>'
    printf '%s' "$RELEASE_NOTES_LIS"
    printf '%s\n' '</ul></body></html>'
  } > "$NOTES_FILE"
fi

CURRENT_LIS=$(extract_lis "$NOTES_FILE")
PREV_GROUPED_HTML=""

if ls -1 "$NOTES_DIR"/*.html >/dev/null 2>&1; then
  tmp_versions="$TMP_DIR/versions.txt"
  tmp_grouped="$TMP_DIR/prev_grouped.html"
  : > "$tmp_versions"
  : > "$tmp_grouped"

  for notes_file in "$NOTES_DIR"/*.html; do
    [ ! -f "$notes_file" ] && continue
    ver=$(basename "$notes_file" .html)
    [ "$ver" = "$SHORT_VERSION" ] && continue
    sortable=$(version_to_sortable "$ver")
    echo "$sortable $ver" >> "$tmp_versions"
  done

  if [ -s "$tmp_versions" ]; then
    tmp_sorted="$TMP_DIR/sorted_versions.txt"
    sort -r "$tmp_versions" > "$tmp_sorted"

    while IFS=' ' read -r sortable_ver ver || [ -n "$ver" ]; do
      [ -z "$ver" ] && continue
      f="$NOTES_DIR/$ver.html"
      [ ! -f "$f" ] && continue

      lis=$(extract_whatsnew_lis "$f")
      [ -z "$lis" ] && lis=$(extract_lis "$f")
      [ -z "$lis" ] && continue

      {
        printf '    <li><strong>v%s</strong>\n' "$ver"
        printf '      <ul>\n'
        printf '%s\n' "$lis"
        printf '      </ul>\n'
        printf '    </li>\n'
      } >> "$tmp_grouped"
    done < "$tmp_sorted"

    if [ -s "$tmp_grouped" ]; then
      PREV_GROUPED_HTML=$(cat "$tmp_grouped")
    fi
  fi
fi

COMBINED_NOTES="$TMP_DIR/notes_${SHORT_VERSION}.html"
{
  printf '%s\n' '<!DOCTYPE html>'
  printf '%s %s%s\n' '<html><head><meta charset="UTF-8"><title>' "$APP_NAME $SHORT_VERSION" '</title></head><body>'
  printf '%s %s%s\n' '<h1>' "$APP_NAME $SHORT_VERSION" '</h1>'
  printf '%s\n' "<h2>What's new</h2>"
  printf '%s\n' '<ul>'
  if [ -n "$CURRENT_LIS" ]; then
    printf '%s\n' "$CURRENT_LIS"
  elif [ -n "$RELEASE_NOTES_LIS" ]; then
    printf '%s' "$RELEASE_NOTES_LIS"
  else
    printf '%s\n' '  <li>Improvements and bug fixes.</li>'
  fi
  printf '%s\n' '</ul>'

  if [ -n "$PREV_GROUPED_HTML" ]; then
    printf '%s\n' '<h2>Previous versions</h2>'
    printf '%s\n' '<ul>'
    printf '%s\n' "$PREV_GROUPED_HTML"
    printf '%s\n' '</ul>'
  fi

  printf '%s\n' '</body></html>'
} > "$COMBINED_NOTES"
run_cmd mv "$COMBINED_NOTES" "$NOTES_FILE"

# ---- URLs -------------------------------------------------------------------
ZIP_URL="$BASE_URL/releases/$ZIP_NAME"
NOTES_URL="$BASE_URL/notes/$SHORT_VERSION.html"
APPCAST_URL="$BASE_URL/$APPCAST_FILE"

PUBDATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S %z")
NEW_ITEM_FILE="$TMP_DIR/new_item.xml"
cat > "$NEW_ITEM_FILE" <<EOF_ITEM
    <item>
      <title>Version $SHORT_VERSION</title>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>
      <enclosure url="$ZIP_URL"
        sparkle:edSignature="$SIG"
        length="$LEN"
        type="application/octet-stream" />
    </item>
EOF_ITEM

ensure_appcast_exists() {
  if [ ! -f "$APPCAST" ]; then
    cat > "$APPCAST" <<EOF_APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$APPCAST_URL</link>
    <description>Release notes and downloads</description>
    <language>en</language>
  </channel>
</rss>
EOF_APPCAST
    echo "• Created new $APPCAST_FILE"
  fi
}

repair_appcast_structure() {
  [ ! -f "$APPCAST" ] && return 0

  local tmp_items="$TMP_DIR/items.xml"
  local tmp_new="$TMP_DIR/new_appcast.xml"
  local bad="${BASE_URL}//"
  local good="${BASE_URL}/"

  awk -v bad="$bad" -v good="$good" '
    BEGIN { initem = 0; buf = "" }
    function trim(s){ sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function extract_tag(body, tag, pos, val, open, after, endpos) {
      open = "<" tag ">"
      pos = index(body, open)
      if (pos == 0) return ""
      after = substr(body, pos + length(open))
      endpos = index(after, "<")
      if (endpos == 0) return ""
      val = substr(after, 1, endpos - 1)
      return trim(val)
    }
    function extract_attr(body, attr, pos, after, q1, val) {
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
      sv  = extract_tag(b, "sparkle:shortVersionString")
      bv  = extract_tag(b, "sparkle:version")
      url = extract_attr(b, "url")
      key = sv "|" bv
      if (url != "" && (url in seenUrl)) { buf = ""; return }
      if (sv != "" && bv != "" && (key in seenKey)) { buf = ""; return }
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

  cat > "$tmp_new" <<EOF_NEW
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$APPCAST_URL</link>
    <description>Release notes and downloads</description>
    <language>en</language>
EOF_NEW

  cat "$tmp_items" >> "$tmp_new"

  cat >> "$tmp_new" <<'EOF_NEW_END'
  </channel>
</rss>
EOF_NEW_END

  run_cmd mv "$tmp_new" "$APPCAST"
  echo "• Repaired appcast: metadata first, URLs normalized, duplicate builds & files removed"
}

remove_existing_version_item() {
  local tmp="$TMP_DIR/appcast_wo_version.xml"
  awk -v ver="$SHORT_VERSION" -v zip="$ZIP_URL" '
    BEGIN { initem = 0; buf = "" }
    function flush_item() {
      if (buf == "") return
      keep = 1
      if (index(buf, "<sparkle:shortVersionString>" ver "</") > 0) keep = 0
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
  run_cmd mv "$tmp" "$APPCAST"
}

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
  run_cmd mv "$tmp" "$APPCAST"
}

ensure_appcast_exists
repair_appcast_structure
remove_existing_version_item
insert_item_after_language

echo "✅ Done"
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $NOTES_FILE"
echo "  $APPCAST"

echo ""
echo "• Staging files for git commit…"
GIT_ROOT=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
  echo "⚠️  Warning: $REPO_ROOT is not inside a git repository — skipping git commit." >&2
  exit 0
}

run_cmd git -C "$GIT_ROOT" add   "$ZIP_PATH"   "$NOTES_FILE"   "$APPCAST"

COMMIT_MSG="Release $APP_NAME $SHORT_VERSION (build $BUILD_VERSION)"
run_cmd git -C "$GIT_ROOT" commit -m "$COMMIT_MSG"
echo "✅ Git committed: $COMMIT_MSG"
