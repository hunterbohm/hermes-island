#!/bin/bash
# Builds the tagged HEAD as a Developer ID signed, Apple-notarized release and publishes it.
# Usage: release.sh [--no-upload]
# Run it on a Mac with the Developer ID certificate in its keychain, under `infisical run --env=prod --` (see RELEASING.md):
#   HEREBY_SIGN_IDENTITY   the certificate's name, "Developer ID Application: <company> (<team id>)"
#   HEREBY_TEAM_ID         the ten-character team id; updates must be signed by it
#   Notarization, one of:  HEREBY_NOTARY_PROFILE (a `notarytool store-credentials` keychain profile), or
#                          HEREBY_NOTARY_KEY (the App Store Connect API key's .p8 text), HEREBY_NOTARY_KEY_ID, HEREBY_NOTARY_ISSUER
#   HERMES_ISLAND_REPO     optional: owner/name the release goes to and installed apps update from; defaults to this clone's GitHub repo
# It writes HermesIsland-<tag>.zip and appcast.json to HERMES_ISLAND_RELEASE_OUT (default .build/release-out/<tag>), checks
# them the way an installed app will, and uploads both to that tag's GitHub release, marked latest. Installed apps offer it
# within a day. --no-upload stops before the upload.
set -euo pipefail
umask 022
upload=1
for argument in "$@"; do
    case "$argument" in
        --no-upload) upload=0 ;;
        *) printf 'usage: release.sh [--no-upload]\n' >&2; exit 2 ;;
    esac
done
root="$(cd "$(dirname "$0")/.." && pwd)"

if ! version="$(git -C "$root" describe --tags --exact-match HEAD 2>/dev/null)" || [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'A release needs HEAD on a release tag like v0.2.0.\n' >&2
    exit 1
fi
if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    printf 'Not releasing: the clone has uncommitted changes, so the build would not match %s.\n' "$version" >&2
    exit 1
fi
missing=()
for name in HEREBY_SIGN_IDENTITY HEREBY_TEAM_ID; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
done
if [[ -z "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    for name in HEREBY_NOTARY_KEY HEREBY_NOTARY_KEY_ID HEREBY_NOTARY_ISSUER; do
        [[ -n "${!name:-}" ]] || missing+=("$name (or HEREBY_NOTARY_PROFILE)")
    done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Not releasing: missing %s. Run it under `infisical run --env=prod --`; see RELEASING.md.\n' "${missing[*]}" >&2
    exit 1
fi
if [[ ! "$HEREBY_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then printf 'HEREBY_TEAM_ID is not a team id.\n' >&2; exit 1; fi
if [[ "$HEREBY_SIGN_IDENTITY" != "Developer ID Application: "*"($HEREBY_TEAM_ID)" ]]; then
    printf 'HEREBY_SIGN_IDENTITY must be a Developer ID Application certificate of team %s.\n' "$HEREBY_TEAM_ID" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "\"$HEREBY_SIGN_IDENTITY\""; then
    printf 'No valid "%s" in the keychain. See RELEASING.md.\n' "$HEREBY_SIGN_IDENTITY" >&2
    exit 1
fi
repo="${HERMES_ISLAND_REPO:-}"
if [[ -z "$repo" ]]; then repo="$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner)"; fi
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then printf 'The repository %s is not owner/name.\n' "$repo" >&2; exit 1; fi
[[ -d "$root/Vendor/FluidAudio" ]] || { printf 'Run scripts/fetch-deps.sh first.\n' >&2; exit 1; }

out="${HERMES_ISLAND_RELEASE_OUT:-$root/.build/release-out/$version}"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
zip="$out/HermesIsland-$version.zip"
download_url="https://github.com/$repo/releases/download/$version/HermesIsland-$version.zip"

printf 'Building %s\n' "$version"
HERMES_ISLAND_SIGN_IDENTITY="$HEREBY_SIGN_IDENTITY" HERMES_ISLAND_VERSION="$version" \
    HERMES_ISLAND_TEAM_ID="$HEREBY_TEAM_ID" HERMES_ISLAND_UPDATE_REPO="$repo" "$root/scripts/build-app.sh"
app="$root/dist/Hermes Island.app"
info="$app/Contents/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info")"
requirement="anchor apple generic and identifier \"$bundle_id\" and certificate leaf[subject.OU] = \"$HEREBY_TEAM_ID\""
codesign --verify --deep --strict -R "=$requirement" "$app"

ditto -c -k --keepParent "$app" "$work/notarize.zip"
if [[ -n "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$HEREBY_NOTARY_PROFILE")
else
    # %b: secret stores that keep one-line values hold the .p8's line breaks as literal \n.
    (umask 077; printf '%b\n' "$HEREBY_NOTARY_KEY" > "$work/notary.p8")
    notary=(--key "$work/notary.p8" --key-id "$HEREBY_NOTARY_KEY_ID" --issuer "$HEREBY_NOTARY_ISSUER")
fi
printf 'Notarizing %s; Apple usually answers in a few minutes.\n' "$version"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json > "$work/notary.json" || true
status="$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    submission="$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)"
    printf 'Notarization ended as "%s".\n' "${status:-unknown}" >&2
    [[ -n "$submission" ]] && xcrun notarytool log "$submission" "${notary[@]}" >&2 || true
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$zip"
length="$(stat -f %z "$zip")"
hash="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
minimum="$(plutil -extract LSMinimumSystemVersion raw -o - "$info")"
cat > "$out/appcast.json" <<JSON
{
  "length" : $length,
  "minimum_system_version" : "$minimum",
  "sha256" : "$hash",
  "url" : "$download_url",
  "version" : "$version"
}
JSON
# The app's own checks, run on the files about to be uploaded.
"$app/Contents/MacOS/HermesIsland" --verify-update "$out/appcast.json" "$zip"
printf 'Built %s and %s\n' "$zip" "$out/appcast.json"
[[ $upload == 1 ]] || exit 0

notes="Signed and notarized build of $version. Download HermesIsland-$version.zip, unzip it, and move Hermes Island to /Applications. Installed copies offer it from the menu bar item."
if gh release view "$version" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$version" "$zip" "$out/appcast.json" --repo "$repo" --clobber
else
    gh release create "$version" "$zip" "$out/appcast.json" --repo "$repo" --verify-tag --title "$version" --notes "$notes"
fi
gh release edit "$version" --repo "$repo" --latest >/dev/null
printf 'Published %s to %s; installed apps offer it within a day.\n' "$version" "$repo"
