#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# release-unified.sh — Sparkle release/appcast tool for multiple apps
# Compatible with /bin/bash 3.2.x on macOS
#
# Usage:
#   scripts/release.sh [--dry-run] [--push] [--rewrite-zip-history] [--require-notarized] [--skip-codesign-preflight] <app-key> /path/to/ExportedApp.app
#   scripts/release.sh [--dry-run] [--push] [--rewrite-zip-history] --prune-only <app-key>
#
# Preflight (release mode):
#   - codesign --verify --deep --strict on the exported .app
#   - Developer ID Application + optional TeamIdentifier check (per-app field 7)
#   - notarization/stapling warning by default; --require-notarized fails if missing
#
# Git:
#   - Requires a git checkout of this repo before writing artifacts
#   - On commit failure, prints recovery steps and exits non-zero
#   - --push runs git push and probes the published appcast URL
#   - --rewrite-zip-history removes stale release .zip blobs from all git history
#     (requires git-filter-repo; use with --push for force-with-lease)
#
# Examples:
#   scripts/release.sh macoutdated ~/Downloads/MacOutdated-1.38.app
#   scripts/release.sh photos-export-gps-fixer ~/Downloads/Photos\ Export\ GPS\ Fixer-2.1.app
#   scripts/release.sh --prune-only macoutdated
#
# To add a new app later, add one more register_app line in the APP CONFIG section
# and put its docs under docs/<app-key>/ unless it is a legacy root-docs app.
# -----------------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

DRY_RUN=false
PRUNE_ONLY=false
REQUIRE_NOTARIZED=false
GIT_PUSH=false
REWRITE_ZIP_HISTORY=false
SKIP_CODESIGN_PREFLIGHT=false
ZIP_HISTORY_REWRITTEN=false
ZIP_HISTORY_PUSH_LEASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --prune-only)
      PRUNE_ONLY=true
      shift
      ;;
    --require-notarized)
      REQUIRE_NOTARIZED=true
      shift
      ;;
    --push)
      GIT_PUSH=true
      shift
      ;;
    --rewrite-zip-history)
      REWRITE_ZIP_HISTORY=true
      shift
      ;;
    --skip-codesign-preflight)
      SKIP_CODESIGN_PREFLIGHT=true
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

# Max appcast entries plus matching zips/notes kept on disk after each release.
APPCAST_KEEP=3

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
# Sparkle CLI tools are expected from a pullable git clone at ~/Developer/Sparkle.
# Keep that clone current with: cd ~/Developer/Sparkle && git pull
# Rebuild sign_update after pulling; release.sh only requires sign_update in SPARKLE_BIN.
SPARKLE_BIN_DEFAULT="$HOME/Developer/Sparkle/bin"
SPARKLE_BIN="${SPARKLE_BIN:-$SPARKLE_BIN_DEFAULT}"
# Ignore stale SPARKLE_BIN from an old shell session when the path no longer exists.
if [ ! -d "$SPARKLE_BIN" ] || [ ! -f "$SPARKLE_BIN/sign_update" ]; then
  if [ -n "${SPARKLE_BIN:-}" ] && [ "$SPARKLE_BIN" != "$SPARKLE_BIN_DEFAULT" ]; then
    echo "Warning: SPARKLE_BIN is not usable ($SPARKLE_BIN); using $SPARKLE_BIN_DEFAULT" >&2
  fi
  SPARKLE_BIN="$SPARKLE_BIN_DEFAULT"
fi
NOTES_TEMPLATE=""

# ---- app registry -----------------------------------------------------------
# Format:
#   key|display name|docs relative path|base URL|minimum system version|appcast filename|expected TeamIdentifier (optional)|public appcast URL (optional)
#
# docs relative path examples:
#   macoutdated               -> docs/macoutdated
#   photos-export-gps-fixer   -> docs/photos-export-gps-fixer
#   .                         -> docs/                (legacy root-docs app)
#
# public appcast URL (field 8): when set, release.sh writes a symlink at
# docs/<filename> pointing at the canonical appcast and uses this URL in the feed.
#
# To add a new app, copy one line and edit the fields.
APP_CONFIGS=""
register_app() {
  APP_CONFIGS="${APP_CONFIGS}$1
"
}

register_app "macoutdated|MacOutdated|macoutdated|https://rphoto.github.io/myapps/macoutdated|15.0|appcast-macoutdated.xml|64SX28238Z"
register_app "photos-export-gps-fixer|Photos Export GPS Fixer|photos-export-gps-fixer|https://rphoto.github.io/myapps/photos-export-gps-fixer|16.0|appcast.xml||https://rphoto.github.io/myapps/appcast.xml"

# Example future app:
# register_app "newapp|NewApp|newapp|https://rphoto.github.io/myapps/newapp|16.0|appcast.xml"

usage() {
  cat >&2 <<USAGE
Usage:
  $0 [--dry-run] [--push] [--rewrite-zip-history] [--require-notarized] [--skip-codesign-preflight] <app-key> /path/to/ExportedApp.app
  $0 [--dry-run] [--push] [--rewrite-zip-history] --prune-only <app-key>

Options:
  --require-notarized       Fail if exported .app is not notarized/stapled (default: warn only)
  --skip-codesign-preflight Skip Developer ID / team checks (not recommended)
  --push                    After a successful commit, git push and probe the appcast URL
  --rewrite-zip-history     Purge release .zip files from git history except zips on disk
                            (requires git-filter-repo; rewrites history — use with --push)

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
  EXPECTED_SIGNING_TEAM_ID=$(printf '%s' "$line" | awk -F'|' '{print ($7 != "" ? $7 : "")}')
  PUBLIC_APPCAST_URL=$(printf '%s' "$line" | awk -F'|' '{print ($8 != "" ? $8 : "")}')

  if [ "$DOCS_REL" = "." ]; then
    REPO_DOCS="$DOCS_ROOT"
  else
    REPO_DOCS="$DOCS_ROOT/$DOCS_REL"
  fi

  RELEASES_DIR="$REPO_DOCS/releases"
  NOTES_DIR="$REPO_DOCS/notes"
  APPCAST="$REPO_DOCS/$APPCAST_FILE"
  BASE_URL="${BASE_URL%/}"
  PUBLIC_APPCAST_URL="${PUBLIC_APPCAST_URL%/}"
  APPCAST_URL="$BASE_URL/$APPCAST_FILE"
  if [ -n "${PUBLIC_APPCAST_URL:-}" ]; then
    APPCAST_URL="$PUBLIC_APPCAST_URL"
    APPCAST_SYMLINK="$DOCS_ROOT/${PUBLIC_APPCAST_URL##*/}"
  else
    APPCAST_SYMLINK=""
  fi
  SAFE_NAME=$(printf '%s' "$APP_NAME" | tr -cd '[:alnum:]._-')
}

# ---- appcast helpers (used by release and --prune-only) ---------------------
write_appcast_shell() {
  local dest="$1"
  cat > "$dest" <<EOF_APPCAST_SHELL
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$APP_NAME Updates</title>
    <link>$APPCAST_URL</link>
    <description>Release notes and downloads</description>
    <language>en</language>
EOF_APPCAST_SHELL
}

ensure_appcast_symlink() {
  [ -n "${APPCAST_SYMLINK:-}" ] || return 0

  local target_rel="${APPCAST#$DOCS_ROOT/}"
  if [ -L "$APPCAST_SYMLINK" ]; then
    local current_target
    current_target=$(readlink "$APPCAST_SYMLINK")
    if [ "$current_target" = "$target_rel" ]; then
      return 0
    fi
  fi

  run_cmd ln -sf "$target_rel" "$APPCAST_SYMLINK"
  echo "• Appcast symlink: ${APPCAST_SYMLINK#$REPO_ROOT/} -> $target_rel"
}

stage_release_paths() {
  run_cmd git -C "$GIT_ROOT" add "$APPCAST" "$RELEASES_DIR" "$NOTES_DIR"
  if [ -n "${APPCAST_SYMLINK:-}" ]; then
    ensure_appcast_symlink
    run_cmd git -C "$GIT_ROOT" add "$APPCAST_SYMLINK"
  fi
}

zip_version_from_name() {
  local name="$1"
  name="${name%.zip}"
  if [ "${name#${SAFE_NAME}-}" != "$name" ]; then
    printf '%s' "${name#${SAFE_NAME}-}"
    return 0
  fi
  printf '%s' "$name"
}

preview_prune_stats() {
  local simulate_version="${1:-}"
  [ ! -f "$APPCAST" ] && return 0

  local stats
  stats=$(awk -v keep="$APPCAST_KEEP" -v releases_dir="$RELEASES_DIR" -v simulate="$simulate_version" '
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
    function zip_exists(url,   fn, path) {
      fn = url
      sub(/^.*\//, "", fn)
      path = releases_dir "/" fn
      return (system("test -f \"" path "\"") == 0)
    }
    function register_item(sv, bv, url) {
      if (sv == "" || bv == "") return
      if (!zip_exists(url)) return
      n++
      builds[n] = bv + 0
      versions[n] = sv
    }
    BEGIN { initem = 0; buf = ""; n = 0 }
    /<item>/ { initem = 1; buf = $0; next }
    initem {
      buf = buf ORS $0
      if ($0 ~ /<\/item>/) {
        sv = extract_tag(buf, "sparkle:shortVersionString")
        bv = extract_tag(buf, "sparkle:version")
        url = extract_attr(buf, "url")
        register_item(sv, bv, url)
        initem = 0
        buf = ""
      }
      next
    }
    END {
      if (simulate != "") {
        found = 0
        for (i = 1; i <= n; i++) {
          if (versions[i] == simulate) { found = 1; break }
        }
        if (!found) {
          n++
          builds[n] = 999999999
          versions[n] = simulate
        }
      }
      total = n
      delete used
      kept = 0
      for (k = 1; k <= keep && k <= n; k++) {
        best = 0
        bestbv = -1
        for (i = 1; i <= n; i++) {
          if (used[i]) continue
          if (builds[i] > bestbv) { bestbv = builds[i]; best = i }
        }
        if (best == 0) break
        used[best] = 1
        kept++
      }
      printf "items=%d kept=%d\n", total, kept
    }
  ' "$APPCAST")

  local total kept zip_count note_count
  local f
  total=$(printf '%s' "$stats" | sed -n 's/.*items=\([0-9]*\).*/\1/p')
  kept=$(printf '%s' "$stats" | sed -n 's/.*kept=\([0-9]*\).*/\1/p')
  zip_count=0
  note_count=0
  if [ -d "$RELEASES_DIR" ]; then
    for f in "$RELEASES_DIR"/*.zip; do
      [ -f "$f" ] && zip_count=$((zip_count + 1))
    done
  fi
  if [ -d "$NOTES_DIR" ]; then
    for f in "$NOTES_DIR"/*.html; do
      [ -f "$f" ] && note_count=$((note_count + 1))
    done
  fi

  local remove_items=$((total - kept))
  local remove_zips=$((zip_count - kept))
  local remove_notes=$((note_count - kept))
  [ "$remove_items" -lt 0 ] && remove_items=0
  [ "$remove_zips" -lt 0 ] && remove_zips=0
  [ "$remove_notes" -lt 0 ] && remove_notes=0

  echo "• Prune (keep $APPCAST_KEEP): $total feed item(s) with zips; would keep $kept"
  echo "  Would remove ~$remove_items appcast item(s), ~$remove_zips zip(s), ~$remove_notes note(s)"
}

prune_old_releases() {
  [ ! -f "$APPCAST" ] && return 0

  local tmp_kept="$TMP_DIR/prune_kept_items.xml"
  local tmp_new="$TMP_DIR/prune_appcast.xml"
  local tmp_keep_versions="$TMP_DIR/prune_keep_versions.txt"
  local total=0
  local kept_count=0

  : > "$tmp_keep_versions"

  awk -v keep="$APPCAST_KEEP" -v releases_dir="$RELEASES_DIR" -v keep_versions_file="$tmp_keep_versions" '
    BEGIN { initem = 0; buf = ""; n = 0 }
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
    function zip_exists(url,   fn, path) {
      fn = url
      sub(/^.*\//, "", fn)
      path = releases_dir "/" fn
      return (system("test -f \"" path "\"") == 0)
    }
    function flush_item() {
      if (buf == "") return
      sv = extract_tag(buf, "sparkle:shortVersionString")
      bv = extract_tag(buf, "sparkle:version")
      url = extract_attr(buf, "url")
      if (sv == "" || bv == "" || !zip_exists(url)) { buf = ""; return }
      n++
      items[n] = buf
      builds[n] = bv + 0
      versions[n] = sv
      buf = ""
    }
    /<item>/ { initem = 1; buf = $0; next }
    initem {
      buf = buf ORS $0
      if ($0 ~ /<\/item>/) { flush_item(); initem = 0 }
      next
    }
    END {
      total = n
      delete used
      kept = 0
      for (k = 1; k <= keep && k <= n; k++) {
        best = 0
        bestbv = -1
        for (i = 1; i <= n; i++) {
          if (used[i]) continue
          if (builds[i] > bestbv) { bestbv = builds[i]; best = i }
        }
        if (best == 0) break
        used[best] = 1
        print items[best]
        print versions[best] >> keep_versions_file
        kept++
      }
      print "PRUNE_STATS total=" total " kept=" kept > "/dev/stderr"
    }
  ' "$APPCAST" > "$tmp_kept" 2> "$TMP_DIR/prune_stats.txt"

  local stats_line
  stats_line=$(cat "$TMP_DIR/prune_stats.txt" 2>/dev/null | grep PRUNE_STATS || true)
  total=$(printf '%s' "$stats_line" | sed -n 's/.*total=\([0-9]*\).*/\1/p')
  kept_count=$(printf '%s' "$stats_line" | sed -n 's/.*kept=\([0-9]*\).*/\1/p')
  [ -z "${total:-}" ] && total=0
  [ -z "${kept_count:-}" ] && kept_count=0

  write_appcast_shell "$tmp_new"
  if [ -s "$tmp_kept" ]; then
    cat "$tmp_kept" >> "$tmp_new"
  fi
  cat >> "$tmp_new" <<'EOF_PRUNE_END'
  </channel>
</rss>
EOF_PRUNE_END
  run_cmd mv "$tmp_new" "$APPCAST"
  ensure_appcast_symlink

  local -a keep_versions=()
  if [ -s "$tmp_keep_versions" ]; then
    while IFS= read -r ver || [ -n "$ver" ]; do
      [ -z "$ver" ] && continue
      keep_versions+=("$ver")
    done < "$tmp_keep_versions"
  fi

  is_kept_version() {
    local v="$1"
    local k
    for k in "${keep_versions[@]}"; do
      [ "$k" = "$v" ] && return 0
    done
    return 1
  }

  local removed_zips=0 removed_notes=0
  local f ver

  if [ -d "$RELEASES_DIR" ]; then
    for f in "$RELEASES_DIR"/*.zip; do
      [ -f "$f" ] || continue
      ver=$(zip_version_from_name "$(basename "$f")")
      if is_kept_version "$ver"; then
        continue
      fi
      run_cmd rm -f "$f"
      removed_zips=$((removed_zips + 1))
    done
  fi

  if [ -d "$NOTES_DIR" ]; then
    for f in "$NOTES_DIR"/*.html; do
      [ -f "$f" ] || continue
      ver=$(basename "$f" .html)
      if is_kept_version "$ver"; then
        continue
      fi
      run_cmd rm -f "$f"
      removed_notes=$((removed_notes + 1))
    done
  fi

  local removed_items=$((total - kept_count))
  [ "$removed_items" -lt 0 ] && removed_items=0
  echo "• Pruned releases: kept $kept_count of $total appcast item(s); removed $removed_items item(s), $removed_zips zip(s), $removed_notes note(s)"
}

ensure_appcast_exists() {
  if [ ! -f "$APPCAST" ]; then
    write_appcast_shell "$APPCAST"
    cat >> "$APPCAST" <<'EOF_APPCAST_NEW_END'
  </channel>
</rss>
EOF_APPCAST_NEW_END
    echo "• Created new $APPCAST_FILE"
  fi
  ensure_appcast_symlink
}

repair_appcast_structure() {
  [ ! -f "$APPCAST" ] && return 0

  local tmp_items="$TMP_DIR/items.xml"
  local tmp_new="$TMP_DIR/new_appcast.xml"
  local bad="${BASE_URL}//"
  local good="${BASE_URL}/"

  awk -v bad="$bad" -v good="$good" -v min_os="$MIN_SYSTEM_VERSION" '
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
      if (min_os != "") {
        gsub(/<sparkle:minimumSystemVersion>[^<]*<\/sparkle:minimumSystemVersion>/, "<sparkle:minimumSystemVersion>" min_os "</sparkle:minimumSystemVersion>", b)
      }
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

  write_appcast_shell "$tmp_new"
  cat "$tmp_items" >> "$tmp_new"
  cat >> "$tmp_new" <<'EOF_REPAIR_END'
  </channel>
</rss>
EOF_REPAIR_END

  run_cmd mv "$tmp_new" "$APPCAST"
  ensure_appcast_symlink
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

require_git_repo() {
  GIT_ROOT=$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: $REPO_ROOT is not inside a git repository." >&2
    echo "Run this script from a clone of the myapps repo so releases can be committed." >&2
    exit 1
  }
}

list_kept_release_zip_paths() {
  local f relpath
  find "$DOCS_ROOT" -path '*/releases/*.zip' -type f 2>/dev/null | sort | while IFS= read -r f; do
    relpath="${f#"$GIT_ROOT"/}"
    printf '%s\n' "$relpath"
  done
}

list_historical_release_zip_paths() {
  git -C "$GIT_ROOT" log --all --pretty=format: --name-only 2>/dev/null \
    | grep -E '^docs/([^/]+/)?releases/[^/]+\.zip$' \
    | sort -u
}

maybe_rewrite_zip_history() {
  local local_tmp=false
  local kept_file hist_file purge_file count
  local origin_url origin_fetch

  ZIP_HISTORY_REWRITTEN=false

  if [ -z "${TMP_DIR:-}" ]; then
    TMP_DIR=$(mktemp -d -t release_rewrite_tmp.XXXXXX)
    local_tmp=true
  fi

  kept_file="$TMP_DIR/kept_release_zips.txt"
  hist_file="$TMP_DIR/historical_release_zips.txt"
  purge_file="$TMP_DIR/purge_release_zips.txt"

  list_kept_release_zip_paths > "$kept_file"
  list_historical_release_zip_paths > "$hist_file"
  comm -23 "$hist_file" "$kept_file" > "$purge_file"

  if [ ! -s "$purge_file" ]; then
    echo "• Zip history cleanup: nothing to remove (history matches on-disk zips)"
    if $local_tmp; then
      rm -rf "$TMP_DIR"
      TMP_DIR=""
    fi
    return 0
  fi

  count=$(wc -l < "$purge_file" | tr -d ' ')
  echo "• Zip history cleanup: $count release zip path(s) to remove from git history"

  if $DRY_RUN; then
    sed 's/^/    /' "$purge_file"
    echo "  Would run: git filter-repo --invert-paths (requires git-filter-repo)"
    echo "  Would push with: git push --force-with-lease origin HEAD"
    if $local_tmp; then
      rm -rf "$TMP_DIR"
      TMP_DIR=""
    fi
    return 0
  fi

  if ! command -v git-filter-repo >/dev/null 2>&1; then
    echo "Error: --rewrite-zip-history requires git-filter-repo." >&2
    echo "Install: brew install git-filter-repo" >&2
    exit 1
  fi

  if ! git -C "$GIT_ROOT" diff --quiet || ! git -C "$GIT_ROOT" diff --cached --quiet; then
    echo "Error: working tree must be clean before --rewrite-zip-history." >&2
    echo "Commit or stash unrelated changes first:" >&2
    git -C "$GIT_ROOT" status --short >&2
    exit 1
  fi

  origin_url=$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null || true)
  origin_fetch=$(git -C "$GIT_ROOT" config --get remote.origin.fetch 2>/dev/null || true)
  ZIP_HISTORY_PUSH_LEASE=$(git -C "$GIT_ROOT" rev-parse origin/main 2>/dev/null || true)

  echo "• Rewriting git history (this may take a minute)…"
  git -C "$GIT_ROOT" filter-repo --force --invert-paths --paths-from-file "$purge_file"

  if [ -n "$origin_url" ]; then
    if git -C "$GIT_ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$GIT_ROOT" remote set-url origin "$origin_url"
    else
      git -C "$GIT_ROOT" remote add origin "$origin_url"
    fi
    if [ -n "$origin_fetch" ]; then
      git -C "$GIT_ROOT" config remote.origin.fetch "$origin_fetch"
    fi
    git -C "$GIT_ROOT" fetch origin
  fi

  git -C "$GIT_ROOT" reflog expire --expire=now --all
  git -C "$GIT_ROOT" gc --prune=now

  ZIP_HISTORY_REWRITTEN=true
  echo "✅ Zip history rewritten ($count path(s) removed from all commits)"

  if $local_tmp; then
    rm -rf "$TMP_DIR"
    TMP_DIR=""
  fi
}

push_and_verify_release() {
  local force_push="${1:-false}"
  local branch
  branch=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD)
  if [ "$force_push" = true ]; then
    echo "• Force-pushing rewritten history to origin ($branch, --force-with-lease)…"
    if [ -n "${ZIP_HISTORY_PUSH_LEASE:-}" ]; then
      if ! run_cmd git -C "$GIT_ROOT" push --force-with-lease="main:$ZIP_HISTORY_PUSH_LEASE" origin HEAD; then
        echo "Error: git push --force-with-lease failed. Rewritten history exists locally at $GIT_ROOT" >&2
        echo "Recovery: git push --force-with-lease=main:$ZIP_HISTORY_PUSH_LEASE origin $branch" >&2
        exit 1
      fi
    elif ! run_cmd git -C "$GIT_ROOT" push --force-with-lease origin HEAD; then
      echo "Error: git push --force-with-lease failed. Rewritten history exists locally at $GIT_ROOT" >&2
      exit 1
    fi
  else
    echo "• Pushing to origin ($branch)…"
    if ! run_cmd git -C "$GIT_ROOT" push origin HEAD; then
      echo "Error: git push failed. Commit exists locally at $GIT_ROOT" >&2
      exit 1
    fi
  fi
  echo "• Verifying published appcast (GitHub Pages may take a minute to update)…"
  if curl -fsS "$APPCAST_URL" >/dev/null; then
    echo "  Appcast reachable: $APPCAST_URL"
  else
    echo "⚠️  Warning: could not fetch $APPCAST_URL yet (Pages deploy may still be in progress)." >&2
  fi
}

stage_release_git() {
  local commit_msg="$1"
  require_git_repo

  echo ""
  echo "• Staging files for git commit…"
  stage_release_paths

  if ! $DRY_RUN && git -C "$GIT_ROOT" diff --cached --quiet; then
    echo "⚠️  No staged changes to commit (artifacts may already match HEAD)." >&2
    if $REWRITE_ZIP_HISTORY; then
      maybe_rewrite_zip_history
    fi
    if $GIT_PUSH; then
      push_and_verify_release "$ZIP_HISTORY_REWRITTEN"
    elif $ZIP_HISTORY_REWRITTEN; then
      echo "• Next step: git push --force-with-lease origin HEAD (history was rewritten)"
    fi
    return 0
  fi

  if $DRY_RUN; then
    run_cmd git -C "$GIT_ROOT" commit -m "$commit_msg"
    echo "✅ Git committed: $commit_msg"
    if $REWRITE_ZIP_HISTORY; then
      maybe_rewrite_zip_history
    fi
    return 0
  fi

  if ! git -C "$GIT_ROOT" commit -m "$commit_msg"; then
    echo "" >&2
    echo "❌ Git commit failed. Release artifacts were written but not committed." >&2
    echo "Recovery:" >&2
    echo "  cd \"$GIT_ROOT\"" >&2
    echo "  git status" >&2
    echo "  git add \"$APPCAST\" \"$RELEASES_DIR\" \"$NOTES_DIR\"" >&2
    if [ -n "${APPCAST_SYMLINK:-}" ]; then
      echo "  git add \"$APPCAST_SYMLINK\"" >&2
    fi
    printf '  git commit -m %q\n' "$commit_msg" >&2
    exit 1
  fi
  echo "✅ Git committed: $commit_msg"

  if $REWRITE_ZIP_HISTORY; then
    maybe_rewrite_zip_history
  fi

  if $GIT_PUSH; then
    push_and_verify_release "$ZIP_HISTORY_REWRITTEN"
  elif $ZIP_HISTORY_REWRITTEN; then
    echo "• Next step: git push --force-with-lease origin HEAD (history was rewritten)"
  else
    echo "• Next step: git push from $GIT_ROOT (or re-run with --push)"
  fi
}

verify_exported_app() {
  if $SKIP_CODESIGN_PREFLIGHT; then
    echo "• Skipping codesign preflight (--skip-codesign-preflight)"
    return 0
  fi

  echo "• Verifying code signature on exported .app…"
  if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    echo "Error: codesign --verify --deep --strict failed for: $APP_PATH" >&2
    echo "Hint: export a Release build signed with your Developer ID certificate." >&2
    exit 1
  fi

  local team authority
  team=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=\(.*\)$/\1/p' | head -1)
  authority=$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n 's/^Authority=\(.*\)$/\1/p' | head -1)

  if [ -z "${authority:-}" ] || ! printf '%s' "$authority" | grep -q "Developer ID Application"; then
    echo "Error: app is not signed with Developer ID Application (Authority: ${authority:-unknown})." >&2
    exit 1
  fi
  echo "  Authority: $authority"

  if [ -n "${EXPECTED_SIGNING_TEAM_ID:-}" ]; then
    if [ "$team" != "$EXPECTED_SIGNING_TEAM_ID" ]; then
      echo "Error: unexpected TeamIdentifier '$team' (expected '$EXPECTED_SIGNING_TEAM_ID')." >&2
      exit 1
    fi
    echo "  TeamIdentifier: $team"
  elif [ -n "${team:-}" ]; then
    echo "  TeamIdentifier: $team"
  fi

  verify_notarization_status
}

verify_notarization_status() {
  if xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
    echo "  Notarization: stapler validate OK"
    return 0
  fi

  if spctl -a -t exec -vv "$APP_PATH" 2>&1 | grep -qi "accepted"; then
    echo "  Notarization: Gatekeeper accepted (spctl)"
    return 0
  fi

  if $REQUIRE_NOTARIZED; then
    echo "Error: exported .app is not notarized/stapled." >&2
    echo "Hint: notarize and staple after Archive → Export, then re-run with the stapled .app." >&2
    exit 1
  fi

  echo "  ⚠️  Warning: notarization/stapling not detected; some users may see Gatekeeper blocks on first launch." >&2
  echo "  Hint: notarize in Xcode or with notarytool, staple, then release — or pass --require-notarized to enforce." >&2
}

run_prune_pipeline() {
  ensure_appcast_exists
  repair_appcast_structure
  prune_old_releases
}

# ---- argument checks --------------------------------------------------------
if $DRY_RUN; then
  echo "⚠️  DRY RUN MODE — no changes will be made"
  echo ""
fi

if $PRUNE_ONLY; then
  if [ $# -ne 1 ]; then
    usage
  fi
  APP_KEY="$1"
  load_app_config "$APP_KEY"

  if $DRY_RUN; then
    echo "• Would prune $APP_NAME release history (keep $APPCAST_KEEP)"
    echo "  Appcast: $APPCAST"
    preview_prune_stats
    if $REWRITE_ZIP_HISTORY; then
      require_git_repo
      TMP_DIR=$(mktemp -d -t release_prune_dryrun_tmp.XXXXXX)
      maybe_rewrite_zip_history
      rm -rf "$TMP_DIR"
      TMP_DIR=""
    fi
    echo ""
    echo "✅ Dry run complete"
    exit 0
  fi

  require_git_repo

  TMP_DIR=$(mktemp -d -t release_prune_tmp.XXXXXX)
  cleanup() { [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
  trap cleanup EXIT

  run_cmd mkdir -p "$RELEASES_DIR" "$NOTES_DIR"
  run_prune_pipeline
  stage_release_git "Prune $APP_NAME releases (keep $APPCAST_KEEP)"
  exit 0
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

require_git_repo

if $DRY_RUN; then
  echo "• Would verify code signature and notarization on exported .app"
  if $REQUIRE_NOTARIZED; then
    echo "  (--require-notarized: would fail if not notarized/stapled)"
  fi
else
  verify_exported_app
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
  preview_prune_stats "$SHORT_VERSION"

  echo ""
  echo "• Would require git repository at: $REPO_ROOT"
  echo "• Would stage files for git commit…"
  stage_release_paths
  run_cmd git -C "$GIT_ROOT" commit -m "$COMMIT_MSG"
  if $GIT_PUSH; then
    if $REWRITE_ZIP_HISTORY; then
      echo "• Would git push --force-with-lease and verify appcast at: $APPCAST_URL"
    else
      echo "• Would git push and verify appcast at: $APPCAST_URL"
    fi
  fi

  if $REWRITE_ZIP_HISTORY; then
    TMP_DIR=$(mktemp -d -t release_dryrun_tmp.XXXXXX)
    maybe_rewrite_zip_history
    rm -rf "$TMP_DIR"
    TMP_DIR=""
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

ensure_appcast_exists
repair_appcast_structure
remove_existing_version_item
insert_item_after_language
prune_old_releases

echo "✅ Done"
echo "Artifacts:"
echo "  $ZIP_PATH"
echo "  $NOTES_FILE"
echo "  $APPCAST"

COMMIT_MSG="Release $APP_NAME $SHORT_VERSION (build $BUILD_VERSION)"
stage_release_git "$COMMIT_MSG"
