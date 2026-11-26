# config

`release.env` is the one place that names the Apple team. It has no comments and no quotes
on purpose: the same file is read by Xcode as an `.xcconfig` (project.yml `configFiles`, all three
configurations) and by shell scripts (`set -a; . config/release.env`).

| Key | Meaning |
|---|---|
| `THEONOTES_TEAM_ID` | The 10-character Apple Team ID. Feeds `DEVELOPMENT_TEAM`, the App Group ids (`$(THEONOTES_TEAM_ID).com.truebrewbirdie.notes` and `.dev`), the keychain access group (through `$(AppIdentifierPrefix)`) and the Info.plist key `THEONOTES_TeamID` that `AppIdentity.teamPrefix` reads when the binary carries no signed application identifier. |
| `THEONOTES_LEGACY_TEAM_ID` | The earlier free personal team. Only the cutover script and the script tests read it (the old App Group container path and sample signing identities); no build setting uses it. |
| `THEONOTES_NOTARY_PROFILE` | Name of the keychain profile made once with `xcrun notarytool store-credentials`. Not a secret; the credentials stay in the keychain. |
| `THEONOTES_PROFILE_APP`, `THEONOTES_PROFILE_APPEX` | Names of the Developer ID provisioning profiles that `scripts/release-mac.sh` puts in the export options: the app's (required for a real run) and the share extension's (empty today: its signature claims no restricted entitlement, so Xcode embeds no profile in it;; T13 confirms). Values may contain spaces, which is why the scripts read this file by key and never `source` it. |

Since the B7 cutover the value is the publishing team `Q446J364FH` (True Brew Birdie Ltd.); before it, every build was
signed by the free personal team named by `THEONOTES_LEGACY_TEAM_ID`. The keychain access group and the App Group changed with it and Jan's data was
re-created, not moved (`docs/release/team-migration.md`). To change the team again:

1. `xcodegen generate`, then `scripts/check-identities.sh` (it reads the value from this file and fails
   on any place that did not follow).
2. Change the one fallback literal in `Packages/TheoNotesCore/Sources/TheoNotesCore/AppIdentity.swift`
   (`AppIdentity.fallbackTeamPrefix`) and the pinned values in `AppIdentityTests`; `check-identities.sh`
   fails until they match.
3. The iOS targets in `project.yml` still carry the OLD team (`THEONOTES_LEGACY_TEAM_ID`) and the old bundle id until B5; `check-identities.sh` pins that as a documented exception and B5 replaces the exception with the rule "iOS reads the same team".

The notary profile and the two profile names can be overridden per machine by an environment variable of the same name; the team cannot (Xcode reads it from this file, so a second source could only disagree). The Developer ID identity needs no key: `scripts/release-mac.sh` looks it up in the keychain by the team id. Secrets never go in this file.

## identity.env and build.xcconfig

`identity.env` holds one line, `THEONOTES_BUNDLE_ROOT=com.truebrewbirdie.theonotes` (since the B7 cutover; it was `com.truebrewbirdie.baerchen`): the root of every bundle id
(`<root>`, `<root>.dev`, `.share`, `.cli`, `.tests`) and of the three exported type ids in the Mac Info.plist.
XcodeGen accepts one config file per configuration, so `build.xcconfig` includes `release.env` and `identity.env`
and `project.yml` points at it. The Swift twin is `LegacyNames.bundleRoot`; `scripts/check-identities.sh` and
`IdentityPinsTests` fail when they differ. The value changed only in the identity cutover (plan task B7).
