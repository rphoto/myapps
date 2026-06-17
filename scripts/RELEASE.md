# Sparkle release process (`release.sh`)

This repository hosts Sparkle appcast XML, release zips, and release-note HTML for apps published via GitHub Pages. The release script lives next to this document.

**Script:** [`release.sh`](release.sh)

## What it does

For a given app key and exported `.app` bundle, `release.sh`:

1. Verifies the exported app is signed (Developer ID; optional team ID check per app).
2. Warns or fails if the app is not notarized/stapled.
3. Prompts for release-note bullet items (interactive).
4. Zips the `.app` with `ditto` into `docs/<app>/releases/`.
5. Signs the zip with Sparkle `sign_update` (EdDSA key in your keychain).
6. Writes `docs/<app>/notes/<version>.html`.
7. Repairs, updates, and prunes the appcast XML (keeps the **3** newest versions).
8. Stages changes and creates a local git commit.

It does **not** push to GitHub unless you pass `--push`. You can also commit and push manually from Terminal.

## Registered apps

| App key | Display name | Docs path | Appcast file |
|---------|--------------|-----------|--------------|
| `macoutdated` | MacOutdated | `docs/macoutdated/` | `appcast-macoutdated.xml` |
| `photos-export-gps-fixer` | Photos Export GPS Fixer | `docs/photos-export-gps-fixer/` | `appcast.xml` |
| `intel-app-cleanup` | Intel Component Manager | `docs/intel-app-cleanup/` | `appcast.xml` |

Add a new app by copying a `register_app` line in `release.sh` (see the APP CONFIG section).

## Prerequisites

### Sparkle CLI (`sign_update`)

Full releases (not `--prune-only`) require Sparkle’s `sign_update` binary on your `PATH`. The script reads `SPARKLE_BIN` if set; otherwise it falls back to `$HOME/Developer/Sparkle/bin`.

**Recommended on this machine:** use the repo’s `.envrc` with [direnv](https://direnv.net/). The checked-in `.envrc` points at the vendored Sparkle tools in the MacOutdated app repo (same 2.9.1 toolchain the app ships with):

```bash
# .envrc (repo root)
export SPARKLE_BIN="$HOME/Documents/git-repo-2025/MacOutdated/Sparkle-2.9.1/bin"
export PATH="$SPARKLE_BIN:$PATH"
```

After cloning `myapps` or editing `.envrc`:

```bash
cd /path/to/myapps
direnv allow
```

direnv blocks loading when `.envrc` changes until you run `direnv allow` again — that is normal security behavior, not a broken install.

Verify:

```bash
echo "$SPARKLE_BIN"
test -x "$SPARKLE_BIN/sign_update" && echo "sign_update OK"
```

**Alternative:** maintain a separate Sparkle git clone (useful after a clean macOS install or when you want the latest Sparkle CLI):

```bash
mkdir -p ~/Developer
git clone https://github.com/sparkle-project/Sparkle.git ~/Developer/Sparkle
cd ~/Developer/Sparkle
# Build sign_update (Xcode or make, per Sparkle docs for your checkout)
```

Then either:

- Point `.envrc` at `export SPARKLE_BIN="$HOME/Developer/Sparkle/bin"`, run `direnv allow`, or
- Export `SPARKLE_BIN` manually for a one-off release.

Pin `SPARKLE_BIN` to a Sparkle version compatible with the app’s embedded framework (MacOutdated uses **2.9.1**).

### EdDSA signing key

`sign_update` uses the Sparkle EdDSA private key stored in your macOS keychain (same key whose public half is in each app’s `SUPublicEDKey`). If signing fails, check Sparkle’s keychain setup docs.

### Exported `.app`

Build in Xcode: **Product → Archive → Distribute App → Developer ID**. Notarize and staple before release when possible (Xcode or `notarytool` + `stapler`). The script warns by default; pass `--require-notarized` to fail instead.

### Git

The script requires a git checkout of this repo. It commits locally; push separately or use `--push`.

## Typical release workflow

```bash
cd ~/Documents/git-repo-2025/myapps
direnv allow    # if you just edited .envrc or cloned the repo

# Optional dry run (no commit; still zips/signs in dry-run mode for preview)
./scripts/release.sh --dry-run macoutdated ~/Downloads/MacOutdated-2.91.app

# Real release
./scripts/release.sh macoutdated ~/Downloads/MacOutdated-2.91.app

# Publish (or use --push on the command above)
git push origin main
```

Replace `macoutdated` and the `.app` path for other registered apps.

### What you will be prompted for

Release notes: enter one change per line; blank line finishes. At least one item is required.

### Artifacts written

For app key `macoutdated` and version `2.91`:

| Output | Path |
|--------|------|
| Zip | `docs/macoutdated/releases/MacOutdated-2.91.zip` |
| Notes | `docs/macoutdated/notes/2.91.html` |
| Appcast | `docs/macoutdated/appcast-macoutdated.xml` |

After each release, **only the three newest** appcast entries (and matching zips/notes) are kept (`APPCAST_KEEP=3` in `release.sh`).

## Command-line options

| Flag | Effect |
|------|--------|
| `--dry-run` | Preview steps; uses a placeholder signature in the appcast preview path |
| `--prune-only <app-key>` | Trim appcast/zips/notes to the last 3 versions without a new build |
| `--push` | After commit, `git push` and probe the live appcast URL |
| `--require-notarized` | Fail if the exported `.app` is not notarized/stapled |
| `--skip-codesign-preflight` | Skip Developer ID / team checks (debug only) |
| `--rewrite-zip-history` | Remove stale release zip blobs from full git history (needs `git-filter-repo`; use with care) |

Examples:

```bash
./scripts/release.sh --prune-only macoutdated
./scripts/release.sh --dry-run --prune-only macoutdated
./scripts/release.sh --push --require-notarized macoutdated ~/Downloads/MacOutdated-2.91.app
```

## Prune-only (no new build)

Use when the feed or `releases/` folder has grown and you only want to collapse history:

```bash
./scripts/release.sh --prune-only macoutdated
```

This does **not** require `sign_update` (the script exits before Sparkle checks). Review the commit diff before pushing.

## Layout on GitHub Pages

Published URLs follow the `register_app` base URL, for example:

- MacOutdated feed: `https://rphoto.github.io/myapps/macoutdated/appcast-macoutdated.xml`
- MacOutdated zips: `https://rphoto.github.io/myapps/macoutdated/releases/...`

Each consumer app’s `Info.plist` `SUFeedURL` must match the canonical appcast URL for its app key.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Sparkle bin directory does not exist` | `SPARKLE_BIN` points at a missing path | Fix `.envrc`, run `direnv allow`, or clone/build Sparkle under `~/Developer/Sparkle` |
| `.envrc is blocked` | `.envrc` changed since last allow | `direnv allow` in the repo root |
| `sign_update` not found | `SPARKLE_BIN` wrong or not on `PATH` | See [Sparkle CLI](#sparkle-cli-sign_update) above |
| Codesign verify failed | Debug export or wrong cert | Re-export Release with Developer ID |
| Commit failed | Hook, identity, or empty stage | Follow the recovery lines the script prints; fix and commit manually |
| Users don’t see update | Forgot `git push` or Pages lag | `git push`; curl the appcast URL |

After a **macOS upgrade**, recreate machine-local paths (`~/Developer/Sparkle`, direnv allow hashes, pyenv `rehash`) as needed. The vendored MacOutdated `Sparkle-2.9.1/bin` path in `.envrc` survives as long as that repo is present on disk.

## Related documentation

- MacOutdated maintainer notes (consumer config, Xcode embed, broader Sparkle review): `MacOutdated/MacOutdated/ReleaseAndSparkleReview.md` in the app repo.
- Shell-wide direnv examples: `~/Documents/shell-setup/README.md` (direnv section).
