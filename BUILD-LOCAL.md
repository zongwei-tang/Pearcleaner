# Personal Build

Build Pearcleaner with your own Apple Development certificate and use it in place of the official app. All bundle identifiers, launchd labels and Mach service names are unchanged, so this build **cannot coexist with the official app**: remove the official app's background components first.

## 1. Prerequisites

- Xcode 27 (macOS 27).
- An Apple ID added in Xcode > Settings > Accounts. A free Personal Team is fine for local use.
- An **Apple Development** certificate: in Accounts, select the team, click Manage Certificates…, click `+`, choose Apple Development. The project uses Manual signing, so Xcode will not create the certificate for you.

## 2. Signing: one place to edit

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Set `DEVELOPMENT_TEAM` in that file to your 10-character Team ID. The file is ignored by git. To find your Team ID:

- In Keychain Access, open the "Apple Development: …" certificate; the Organizational Unit (OU) field is the Team ID, or
- Run `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` and read the value after `OU=`.

`DEVELOPMENT_TEAM` is **required**. It selects the signing certificate and also names the App Group `TEAMID.com.alienator88.Pearcleaner`. If it is empty, the signing identity is ambiguous and the App Group becomes an invalid value starting with `.`.

Notes:

- All signing settings live in `Config/Signing.xcconfig`: Manual, Apple Development, no provisioning profile. No target overrides these keys.
- **Do not switch to Automatic.** These bundle IDs are registered to the upstream author's team, so Automatic signing fails with "app identifier … is not available".
- **Do not change signing in Xcode's Signing & Capabilities tab.** Changes there are written as target-level settings and override the xcconfig.
- **Never use ad-hoc signing** ("Sign to Run Locally", or `CODE_SIGN_IDENTITY = -`). Ad-hoc code has no certificate chain. Upstream's root helper only compared certificate arrays, so `[] == []` matched and any ad-hoc process on the Mac could run commands as root through the helper. This build rejects ad-hoc clients, but an ad-hoc build would also lose its Full Disk Access grant on every rebuild.
- `Builds/ExportOptions.plist` is still the upstream author's release configuration and is not used here.

## 3. Before installing: remove the official app

1. Open the **official** Pearcleaner:
   - Settings > Helper: turn the helper off (this unregisters the helper daemon).
   - Settings > General: turn off Sentinel Monitor and Finder Extension.
2. Quit Pearcleaner.
3. Move the official app out of `/Applications`. Back it up first, so two apps with the same bundle ID never sit on the system at once:
   ```sh
   ditto -c -k --keepParent /Applications/Pearcleaner.app ~/Pearcleaner-official.zip
   ```
   Then delete `/Applications/Pearcleaner.app` in Finder.
4. Optional: remove the old Pearcleaner entry with `−` in System Settings > Privacy & Security > Full Disk Access.

## 4. Build

Use the **"Pearcleaner Release"** scheme. Archiving the "Pearcleaner Debug" scheme uses the Debug configuration.

Command line (recommended, the output path is fixed):

```sh
xcodebuild -project Pearcleaner.xcodeproj -scheme "Pearcleaner Release" -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build
ditto build/Build/Products/Release/Pearcleaner.app /Applications/Pearcleaner.app
```

`-allowProvisioningUpdates` has no effect with Manual signing and no profile; keeping it is harmless.

In Xcode: select the "Pearcleaner Release" scheme and run Product > Build. In the Products group of the project navigator, right-click `Pearcleaner.app`, choose Show in Finder, and copy it to `/Applications`. Alternatively use Product > Archive, right-click the archive in Organizer, choose Show in Finder, and take the `.app` from `Products/Applications/` inside the `.xcarchive`.

**Copy the app to `/Applications` before enabling the helper.** Background item (BTM) records are tied to the app's path, so do not register from DerivedData or the `build/` folder.

## 5. First launch

1. Launch the new build from `/Applications`.
2. Settings > Helper: turn the helper on, then approve it in System Settings > General > Login Items & Extensions. Run `whoami` in the Helper Playground under Settings > Helper; it should return `root`. Apple does not document whether a helper daemon signed by a free Personal Team keeps working long term; this is unverified.
3. In System Settings > Privacy & Security > Full Disk Access, add `/Applications/Pearcleaner.app` and turn it on. The new signature has a different designated requirement, so the official app's grant does not carry over. Rebuilding with the same certificate keeps the grant.
4. Optional: turn Sentinel Monitor and Finder Extension back on.
5. If you saved a sudo password in the official app, the first Keychain read may ask for permission (inferred). Allow it, or save the password again.
6. Recommended: turn on the delete confirmation in Settings > General, and review the preselected items before every uninstall.

## 6. Verify

```sh
codesign -dv --verbose=2 /Applications/Pearcleaner.app      # Authority=Apple Development: …, TeamIdentifier=your Team ID
codesign --verify --deep --strict --verbose=2 /Applications/Pearcleaner.app
codesign -dv /Applications/Pearcleaner.app/Contents/MacOS/PearcleanerHelper   # the helper must show your TeamIdentifier too

# App Group: these 4 values must be identical, all TEAMID.com.alienator88.Pearcleaner
codesign -d --entitlements - /Applications/Pearcleaner.app
codesign -d --entitlements - /Applications/Pearcleaner.app/Contents/PlugIns/FinderOpen.appex
plutil -extract PearcleanerAppGroup raw /Applications/Pearcleaner.app/Contents/Info.plist
plutil -extract PearcleanerAppGroup raw /Applications/Pearcleaner.app/Contents/PlugIns/FinderOpen.appex/Contents/Info.plist
```

`spctl -a -vv /Applications/Pearcleaner.app` reports `rejected` for an Apple Development signed, non-notarized app. That is expected. A locally built app has no quarantine attribute, so Gatekeeper does not block it. It is blocked only if the app was copied from elsewhere and carries the quarantine attribute. Since macOS 15, right-click > Open no longer bypasses this; click Open Anyway in System Settings > Privacy & Security, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Pearcleaner.app
```

## 7. Automatic updates are disabled

The upstream updater (AlinFoundation) downloads a zip from the alienator88/Pearcleaner GitHub Releases, compares versions as strings, runs `rm -rf` on the current app and unpacks over it, and never checks the signature. As soon as upstream publishes a release, it would silently replace the personal build with the official one. `Pearcleaner/PearcleanerApp.swift` therefore:

- Sets owner and repo to empty strings, so no release can be found: Check for Updates and Refresh do nothing, and nothing is downloaded or installed.
- Forces the update frequency to Never on every launch, so no check runs at startup.
- Turns announcements off.

To restore upstream behavior, revert to the original line given in that file's comment.

## 8. Roll back to the official app

1. In the personal build, turn off Helper, Sentinel Monitor and Finder Extension, then quit.
2. Delete `/Applications/Pearcleaner.app`.
3. Restore the backup: `ditto -x -k ~/Pearcleaner-official.zip /Applications`, or download it again from the upstream GitHub Releases.
4. Launch the official app, turn the Helper back on and approve it in Login Items & Extensions, and grant Full Disk Access again. Both builds share one settings domain and the personal build set the update frequency to Never, so pick an update frequency again in Settings > Update.
