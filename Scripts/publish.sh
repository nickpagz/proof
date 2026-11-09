#!/bin/bash
# Publishes a Proof release to GitHub Releases, which doubles as the app's update feed.
#
# Usage: Scripts/publish.sh <version> [--notes-file FILE] [--local] [--dry-run]
#   <version>      x.y.z, greater than the version in Scripts/Info.plist
#   --notes-file   Markdown release notes, also shown inside the app. Default: commit subjects
#                  since the previous tag.
#   --local        build, zip and sign into dist/ without touching git or GitHub, then print how
#                  to point an installed copy at dist/ as its feed. Skips the DMG.
#   --dry-run      everything except the push and the GitHub release (commits and tags locally)
#
# Needs: gh (logged in), the dev signing certificate (Scripts/make-dev-cert.sh),
# .secrets/update-signing-key (Scripts/sign-manifest.sh keygen) and .secrets/wpcom.env.
# Every step checks whether it already happened, so a run that failed halfway can be rerun.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="nickpagz/proof"
BUNDLE_ID="io.github.nickpagz.proof"
PLIST="$ROOT/Scripts/Info.plist"
DIST="$ROOT/dist"
KEY="$ROOT/.secrets/update-signing-key"
CONFIG_SWIFT="$ROOT/Sources/Proof/Update/UpdateConfig.swift"

VERSION=""; NOTES_FILE=""; LOCAL=0; DRY_RUN=0
while (( $# )); do
    case "$1" in
        --notes-file) NOTES_FILE="$2"; shift ;;
        --local) LOCAL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 64 ;;
        *) VERSION="$1" ;;
    esac
    shift
done
die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "give a version like 0.2.0"
TAG="v$VERSION"
ZIP="$DIST/Proof-$VERSION.zip"
DMG="$DIST/Proof-$VERSION.dmg"
MANIFEST="$DIST/latest.json"
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/Proof-$VERSION.zip"
NOTES_URL="https://github.com/$REPO/releases/tag/$TAG"
cd "$ROOT"

step "Checking prerequisites"
[[ -f "$KEY" ]] || die "no update signing key. Run: Scripts/sign-manifest.sh keygen .secrets/update-signing-key"
[[ -f "$ROOT/.secrets/wpcom.env" || -n "${WPCOM_CLIENT_SECRET:-}" ]] || echo "warning: no WordPress.com client secret (.secrets/wpcom.env); this build cannot sign in to WordPress.com" >&2
if [[ -z "${SIGN_IDENTITY:-}" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"Proof Dev"'; then
    die "no signing certificate. Run Scripts/make-dev-cert.sh (every release must be signed with the same identity)"
fi
[[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]] && die "notes file not found: $NOTES_FILE"
grep -q '"[0-9a-f]\{8\}": "' "$CONFIG_SWIFT" || die "UpdateConfig.swift ships no public key; paste the line that keygen printed"

if (( ! LOCAL )); then
    command -v gh >/dev/null || die "gh is not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
    git remote get-url origin | grep -qE "github\.com[:/]$REPO(\.git)?$" || die "origin is not $REPO"
    [[ "$(git branch --show-current)" == "trunk" ]] || die "release from trunk"
    git fetch -q origin trunk
    (( $(git rev-list --count HEAD..origin/trunk) == 0 )) || die "trunk is behind origin; pull first"
    HEAD_SUBJECT="$(git log -1 --pretty=%s)"
    AHEAD="$(git rev-list --count origin/trunk..HEAD)"
    if (( AHEAD > 1 )) || { (( AHEAD == 1 )) && [[ "$HEAD_SUBJECT" != "Release $TAG" ]]; }; then
        die "trunk has unpushed commits; push them before releasing"
    fi
    [[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
    CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    if [[ "$HEAD_SUBJECT" != "Release $TAG" ]]; then
        [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$CURRENT" != "$VERSION" ]] \
            || die "$VERSION is not newer than the current version $CURRENT"
        step "Committing the version bump and tagging $TAG"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
        git add "$PLIST"
        git commit -q -m "Release $TAG"
    else
        echo "HEAD is already the release commit for $TAG"
    fi
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || die "tag $TAG exists and points at another commit"
    else
        git tag -a "$TAG" -m "Proof $VERSION"
    fi
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

step "Building Proof $VERSION ($BUILD_NUMBER)"
APP_VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" REQUIRE_SIGNING=1 "$ROOT/Scripts/bundle.sh" release
APP="$ROOT/build/Proof.app"
codesign --verify --deep --strict "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || die "built bundle has the wrong version"
mkdir -p "$DIST"

step "Zipping"
rm -f "$ZIP"
# ditto keeps the signature, resource forks and symlinks intact; the updater unpacks with ditto too.
ditto -c -k --keepParent "$APP" "$ZIP"
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/Proof.app" || die "the zipped app no longer passes codesign"
rm -rf "$CHECK"

if (( ! LOCAL )); then
    step "Disk image"
    "$ROOT/Scripts/make-dmg.sh"
    [[ -f "$DMG" ]] || die "expected $DMG"
fi

step "Signing the update manifest"
NOTES_TMP="$(mktemp)"
if [[ -n "$NOTES_FILE" ]]; then
    cp "$NOTES_FILE" "$NOTES_TMP"
else
    PREVIOUS="$(git describe --tags --abbrev=0 --exclude "$TAG" 2>/dev/null || true)"
    git log --no-merges --invert-grep --grep='^Release v' --pretty='- %s' ${PREVIOUS:+"$PREVIOUS"..}HEAD > "$NOTES_TMP"
fi
"$ROOT/Scripts/sign-manifest.sh" sign --key "$KEY" --out "$MANIFEST" --bundle-id "$BUNDLE_ID" \
    --version "$VERSION" --build "$BUILD_NUMBER" \
    --min-os "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" \
    --zip "$ZIP" --zip-url "$ZIP_URL" --notes-file "$NOTES_TMP" --release-notes-url "$NOTES_URL"

step "Verifying the manifest with the public key the app ships"
KEY_ID="$(plutil -extract keyId raw -o - "$MANIFEST")"
PUBLIC_KEY="$(grep -oE "\"$KEY_ID\": *\"[A-Za-z0-9+/=]+\"" "$CONFIG_SWIFT" | sed -E 's/.*: *"([^"]+)"/\1/' | head -1)"
[[ -n "$PUBLIC_KEY" ]] || die "UpdateConfig.swift does not contain public key $KEY_ID; the app could not verify this release"
"$ROOT/Scripts/sign-manifest.sh" verify --manifest "$MANIFEST" --public-key "$PUBLIC_KEY" --zip "$ZIP" --bundle-id "$BUNDLE_ID"

step "Checksums"
(cd "$DIST" && shasum -a 256 "Proof-$VERSION.zip" $( [[ -f "$DMG" ]] && echo "Proof-$VERSION.dmg" ) | tee SHA256SUMS.txt)

if (( LOCAL )); then
    cat <<EOF

Local release is in dist/. To test the updater against it from an installed copy of the app:
  python3 -m http.server -d dist 8000 --bind 127.0.0.1
  defaults write $BUNDLE_ID updateFeedURL http://127.0.0.1:8000/latest.json
  … Settings → Updates → Check Now, or: /Applications/Proof.app/Contents/MacOS/Proof --check-update
  defaults delete $BUNDLE_ID updateFeedURL        # back to GitHub
EOF
    exit 0
fi

RELEASE_NOTES="$(mktemp)"
{
    cat "$NOTES_TMP"
    printf '\n\n### Install\n\n```\ncurl -fsSL https://raw.githubusercontent.com/%s/trunk/install.sh | sh\n```\n' "$REPO"
    printf '\nOr download the DMG and drag Proof to Applications.\n\n### SHA-256\n\n```\n'
    cat "$DIST/SHA256SUMS.txt"
    printf '```\n'
} > "$RELEASE_NOTES"

if (( DRY_RUN )); then
    step "Dry run: stopping before push and release"
    echo "Would push $TAG and publish:"; ls -la "$ZIP" "$DMG" "$MANIFEST"
    echo "Release notes:"; cat "$RELEASE_NOTES"
    exit 0
fi

step "Pushing trunk and $TAG"
git push --follow-tags origin trunk

step "Publishing the GitHub release"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" "$DMG" "$MANIFEST" --clobber -R "$REPO"
    gh release edit "$TAG" --notes-file "$RELEASE_NOTES" --latest -R "$REPO"
else
    gh release create "$TAG" "$ZIP" "$DMG" "$MANIFEST" -R "$REPO" --verify-tag --latest \
        --title "Proof $VERSION" --notes-file "$RELEASE_NOTES"
fi

step "Checking the published feed"
POST="$(mktemp -d)"
gh release download "$TAG" -R "$REPO" -p latest.json -D "$POST"
cmp -s "$POST/latest.json" "$MANIFEST" && echo "latest.json on GitHub matches the signed manifest" || die "the uploaded latest.json differs from dist/latest.json"
if curl -fsSL -o "$POST/public.json" "https://github.com/$REPO/releases/latest/download/latest.json" 2>/dev/null; then
    cmp -s "$POST/public.json" "$MANIFEST" && echo "the public feed URL serves this release" || echo "warning: the public feed URL serves a different manifest (another release marked latest?)"
else
    echo "note: the public feed URL is not reachable anonymously yet (private repo?); the app will update once the repo is public"
fi
rm -rf "$POST" "$NOTES_TMP" "$RELEASE_NOTES"
echo
echo "Published https://github.com/$REPO/releases/tag/$TAG"
