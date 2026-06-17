# Adding Sparkle To An App

This is the checklist for adding a new macOS app to the shared `myapps` Sparkle release flow. There are two separate pieces:

1. The app must embed and configure Sparkle.
2. The `myapps` repo must know how to publish that app's appcast, release zip, and release notes.

Use this with `scripts/RELEASE.md`, which documents the day-to-day release command once an app is registered.

## 1. Choose The Appcast Shape

Pick these values before editing anything:

| Value | Example | Notes |
|-------|---------|-------|
| App key | `intel-app-cleanup` | Stable CLI key passed to `scripts/release.sh`. Prefer lowercase kebab-case. |
| Display name | `Intel Component Manager` | Human-readable name used in release commits and appcast title. |
| Docs path | `intel-app-cleanup` | Creates/uses `docs/<docs-path>/`. Use `.` only for legacy root-docs apps. |
| Base URL | `https://rphoto.github.io/myapps/intel-app-cleanup` | Public GitHub Pages folder for releases, notes, and appcast. |
| Minimum system version | `26.0` | Must match what Sparkle should enforce, usually the app's `LSMinimumSystemVersion`. |
| Appcast filename | `appcast.xml` | Use a unique name or a per-app folder to avoid collisions. |
| Expected TeamIdentifier | `64SX28238Z` | Optional but recommended. Release preflight fails if the exported app is signed by a different team. |
| Public appcast URL | blank | Optional legacy/compat URL. Leave blank for normal per-app appcasts. |

The app's `SUFeedURL` must exactly match the public appcast URL produced from these fields. For normal per-app docs paths, that is:

```text
<base-url>/<appcast-filename>
```

## 2. Add Sparkle To The App

In the app repo:

1. Add Sparkle to the app target.
   - Preferred: Swift Package Manager, repository `https://github.com/sparkle-project/Sparkle`.
   - Pin the package with `Package.resolved` so the framework version is repeatable.
   - Link/embed the `Sparkle` product in the app target.

2. Add Sparkle keys to the app's `Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://rphoto.github.io/myapps/<app-key>/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>JUa6oGheXaqc9a4SXPDT28KeH1bNFFHsRdjRkOzovZs=</string>
```

Use the existing shared public key only when the app will be signed with the existing Sparkle private key in the release keychain. If you generate a new keypair, put that new public key in the app and make sure `sign_update` can access the matching private key before release.

3. Wire a user-visible update action.
   - SwiftUI apps should create an `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` in the `App` type.
   - Add a `Check for Updates...` command that calls `updater.checkForUpdates`.
   - Observe `SPUUpdater.canCheckForUpdates` so the menu item disables itself when Sparkle is not ready.

4. Confirm the app version fields are present and incrementing:
   - `CFBundleShortVersionString`
   - `CFBundleVersion`

Sparkle uses `CFBundleVersion` to decide whether a published item is newer. Do not publish two different app builds with the same build number.

## 3. Register The App In `myapps`

Edit `scripts/release.sh` and add one `register_app` line in the APP CONFIG section:

```bash
register_app "<app-key>|<display name>|<docs-path>|<base-url>|<minimum-system-version>|<appcast-filename>|<expected-team-id>|<public-appcast-url>"
```

Normal example:

```bash
register_app "intel-app-cleanup|Intel Component Manager|intel-app-cleanup|https://rphoto.github.io/myapps/intel-app-cleanup|26.0|appcast.xml|64SX28238Z"
```

Legacy public appcast URL example, only when compatibility requires a root-level feed URL:

```bash
register_app "photos-export-gps-fixer|Photos Export GPS Fixer|photos-export-gps-fixer|https://rphoto.github.io/myapps/photos-export-gps-fixer|16.0|appcast.xml||https://rphoto.github.io/myapps/appcast.xml"
```

Also update `scripts/RELEASE.md` so the app appears in the Registered apps table. Update the root `README.md` if the app list in the release section names individual apps.

Do not manually create release zips, notes, or appcast items for the first release. `scripts/release.sh` creates `docs/<docs-path>/appcast.xml`, `notes/`, and `releases/` when the first real release runs.

## 4. Verify Before Releasing

From the app repo, resolve packages and build with a local DerivedData path:

```bash
xcodebuild -resolvePackageDependencies \
  -project YourApp.xcodeproj \
  -scheme YourScheme \
  -derivedDataPath .build/DerivedData

xcodebuild \
  -project YourApp.xcodeproj \
  -scheme YourScheme \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build
```

Verify the built app:

```bash
test -d ".build/DerivedData/Build/Products/Debug/Your App.app/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' ".build/DerivedData/Build/Products/Debug/Your App.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' ".build/DerivedData/Build/Products/Debug/Your App.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ".build/DerivedData/Build/Products/Debug/Your App.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ".build/DerivedData/Build/Products/Debug/Your App.app/Contents/Info.plist"
```

From the `myapps` repo, verify the release registration with a dry run:

```bash
./scripts/release.sh --dry-run <app-key> /path/to/ExportedApp.app
```

A successful dry run should show these target paths:

```text
docs/<docs-path>/releases/<SafeDisplayName>-<version>.zip
docs/<docs-path>/notes/<version>.html
docs/<docs-path>/<appcast-filename>
```

## 5. First Real Release

1. Archive and export the app from Xcode using Developer ID distribution.
2. Notarize and staple the exported `.app` when possible.
3. In `myapps`, make sure Sparkle CLI tools are available:

```bash
echo "$SPARKLE_BIN"
test -x "$SPARKLE_BIN/sign_update" && echo "sign_update OK"
```

4. Run the release:

```bash
./scripts/release.sh --require-notarized <app-key> /path/to/ExportedApp.app
```

If notarization is not ready yet, omit `--require-notarized`; the script will warn instead of failing. For published releases, notarized and stapled builds are strongly preferred.

5. Review the generated commit and appcast diff.
6. Push the `myapps` repo, or use `--push` on the release command.
7. Confirm the published appcast is reachable:

```bash
curl -fsS https://rphoto.github.io/myapps/<docs-path>/<appcast-filename> >/dev/null
```

## Common Pitfalls

- `SUFeedURL` in the app does not match the registered appcast URL.
- The app's `CFBundleVersion` did not increase, so Sparkle does not offer the update.
- `SPARKLE_BIN` points to a Sparkle toolchain that is missing `sign_update`.
- The exported `.app` is signed with Apple Development instead of Developer ID Application.
- The TeamIdentifier in `release.sh` does not match the exported app signature.
- The app was zipped manually instead of through `release.sh`, so the appcast signature/length do not match.
- GitHub Pages has not deployed yet after pushing; wait briefly and curl the appcast again.
