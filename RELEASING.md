# Releasing the signed app

`scripts/release.sh` turns a release tag into a Developer ID signed, Apple-notarized download, and installed copies
offer it from their menu. A source build (`scripts/build-app.sh`) needs none of this.

## How the pieces fit

- **Developer ID certificate.** Signs the app so macOS knows who made it. macOS keys the Microphone and Accessibility
  grants to the app's bundle id (`dev.hermes-island.app`) and its signer, so every release keeps the same bundle id and
  the same team, and the grants survive updates.
- **Notarization.** Apple scans the signed app and issues a ticket, which `stapler` attaches to the app, so Gatekeeper
  opens it without a warning, even offline.
- **Feed.** `appcast.json`, a file on the release next to the zip. A signed app reads
  `https://github.com/<owner>/<repo>/releases/latest/download/appcast.json` at most once a day, and only while
  **Check for Updates Automatically** in its menu is on. It holds the version, the zip's URL, size and SHA-256.
- **The check.** The app installs an update only if the zip matches the feed's size and SHA-256, holds one app that is
  `dev.hermes-island.app` at the version the feed names, has a code signature issued through Apple to the same team
  (`anchor apple generic and identifier "dev.hermes-island.app" and certificate leaf[subject.OU] = "<team id>"`), and
  Gatekeeper accepts it, which for a downloaded app means notarized. The team id is stamped into the signed app's
  Info.plist (`HermesIslandTeamID`) at release time. Changing the feed on GitHub cannot make the app install anything
  the developer's certificate did not sign, and an older signed zip under a newer version number fails the version
  check. There is no separate update key to lose or keep.
- **Source builds** have neither Info.plist key, so they never look for updates.

An update quits the app and a launchd job (`dev.hermes-island.app.update`) runs the new release's own
`Contents/Resources/scripts/install-update.sh`: it swaps the bundle in place, redoes the Open at Login steps macOS 26
needs when that is on (the same steps as `install()` in `hermes-plugin/island.py`), and opens the new copy. It writes
its log and result under `~/Library/Application Support/Hermes Island/update/`.

## One-time setup

1. **Certificate.** The account holder makes a "Developer ID Application" certificate and installs it in the login
   keychain of the Mac that releases. `security find-identity -v -p codesigning` lists
   `"Developer ID Application: <company> (<TEAM ID>)"`.
2. **Notarization login:** an App Store Connect API key (Users and Access, Integrations, Team Keys), or a keychain
   profile made with `xcrun notarytool store-credentials`.
3. **Secrets** `release.sh` reads from the environment, kept in the secret store and injected with
   `infisical run --env=prod --`:

   | Name | Value |
   | --- | --- |
   | `HEREBY_SIGN_IDENTITY` | the certificate's full name |
   | `HEREBY_TEAM_ID` | the ten-character team id |
   | `HEREBY_NOTARY_KEY`, `HEREBY_NOTARY_KEY_ID`, `HEREBY_NOTARY_ISSUER` | the API key's `.p8` text (line breaks may be stored as `\n`), key id, issuer id |
   | or `HEREBY_NOTARY_PROFILE` | the keychain profile name, instead of the three above |
   | `HERMES_ISLAND_REPO` (optional) | `owner/name` to publish to; defaults to this clone's GitHub repo |

   The names say Hereby because one company certificate and notary key sign all of the owner's apps.

## Each release

1. Bump nothing in the repo: the version comes from the tag. Tag the commit `vX.Y.Z` (never reuse a tag) and check it
   out clean: `scripts/fetch-deps.sh` once per clone, then `git switch --detach vX.Y.Z`.
2. `infisical run --env=prod -- scripts/release.sh` builds, signs (hardened runtime, `HermesIsland.entitlements`),
   notarizes (a few minutes), staples, zips, writes `appcast.json`, runs the app's own `--verify-update` on the zip and
   feed, uploads both to that tag's GitHub release and marks it latest. Installed apps offer it within a day, or at once
   from **Check for Updates…**. `--no-upload` stops after writing the files to `.build/release-out/<tag>`.
3. The tag must exist on GitHub first (`git push origin vX.Y.Z`): `gh release create --verify-tag` refuses otherwise.

## The first signed install on a Mac that ran a source build

A source build is signed by a local certificate, so its grants belong to that signer. The first signed release is a new
signer: macOS asks once more for Accessibility and the Microphone, and the first update from a source build does not
happen by itself (a source build has no update check). Download the zip from the release, quit Hermes Island, replace
`/Applications/Hermes Island.app` with the new one, and open it. If Open at Login was on, turn it off and on once in the
menu. Later signed updates keep the grants.
