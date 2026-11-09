#!/bin/bash
# Builds the Proof executable with SwiftPM and assembles a signed .app bundle.
# Usage: Scripts/bundle.sh [debug|release]
# Environment:
#   SIGN_IDENTITY    code-signing certificate name; defaults to the dev cert from
#                    Scripts/make-dev-cert.sh if present, else ad-hoc ("-")
#   REQUIRE_SIGNING  when set, fail instead of falling back to ad-hoc (releases must be
#                    signed with a stable identity or the self-updater will refuse them)
#   APP_VERSION      overrides CFBundleShortVersionString in the built bundle
#   BUILD_NUMBER     overrides CFBundleVersion in the built bundle (publish.sh passes the
#                    commit count, so build numbers only go up)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="Proof"
BUNDLE_ID="io.github.nickpagz.proof"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
# Signing identity: $SIGN_IDENTITY, else a dev certificate from Scripts/make-dev-cert.sh if one
# exists, else ad-hoc. A stable identity is what keeps Screen Recording, mic, camera and Keychain
# grants valid across rebuilds; ad-hoc changes identity every build and invalidates them.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    # Only the self-signed "Proof Dev" certificate: it names no person, so the signature doesn't
    # carry an email address the way an Apple Development certificate does.
    if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Proof Dev"'; then
        IDENTITY="Proof Dev"
    fi
fi
if [[ -z "$IDENTITY" ]]; then
    if [[ -n "${REQUIRE_SIGNING:-}" ]]; then
        echo "error: REQUIRE_SIGNING is set but no code-signing certificate was found. Run Scripts/make-dev-cert.sh or set SIGN_IDENTITY." >&2
        exit 1
    fi
    IDENTITY="-"
    echo "warning: no code-signing certificate found; signing ad-hoc. Permissions will reset on every rebuild. Run Scripts/make-dev-cert.sh once." >&2
fi

cd "$ROOT"
# The default "swiftbuild" build system fails without Xcode installed; the
# native one works with Command Line Tools alone.
# pipefail makes a compiler failure abort the script; the grep only hides SwiftPM's deprecation notice.
swift build --build-system native -c "$CONFIG" 2>&1 | { grep -v "has been deprecated" || true; }
BIN_DIR="$(swift build --build-system native -c "$CONFIG" --show-bin-path 2>/dev/null)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: build did not produce $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
for asset in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    [[ -f "$ROOT/Assets/$asset" ]] && cp "$ROOT/Assets/$asset" "$APP/Contents/Resources/$asset"
done

# WordPress.com OAuth app (ID and secret): from the environment or .secrets/wpcom.env (gitignored).
# Written into the built bundle's Info.plist only, before signing seals it.
wpcom_value() {   # $1 variable name
    local value="${!1:-}"
    if [[ -z "$value" && -f "$ROOT/.secrets/wpcom.env" ]]; then
        value="$(grep -E "^$1=" "$ROOT/.secrets/wpcom.env" | head -1 | cut -d= -f2- | tr -d "\"'" | tr -d '[:space:]')"
    fi
    printf '%s' "$value"
}
CLIENT_ID="$(wpcom_value WPCOM_CLIENT_ID)"
SECRET="$(wpcom_value WPCOM_CLIENT_SECRET)"
if [[ -n "$CLIENT_ID" && -n "$SECRET" ]]; then
    /usr/libexec/PlistBuddy -c "Add :ProofWPComClientID string $CLIENT_ID" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :ProofWPComClientSecret string $SECRET" "$APP/Contents/Info.plist"
    echo "Embedded the WordPress.com app ID and secret."
else
    echo "warning: no WordPress.com app (set WPCOM_CLIENT_ID and WPCOM_CLIENT_SECRET, or create .secrets/wpcom.env); WordPress.com sign-in is off in this build" >&2
fi

# Version and build number, written into the built bundle only (Scripts/Info.plist keeps 1).
PLIST="$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$PLIST"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi
VERSION_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST"))"

CODESIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")
if [[ "$IDENTITY" == Developer\ ID* ]]; then
    # Distribution builds: hardened runtime and entitlements are required for notarization.
    CODESIGN_ARGS+=(--options runtime --timestamp --entitlements "$ROOT/Scripts/Proof.entitlements")
fi
# Finder info and other extended attributes make codesign refuse, and iCloud adds them to a bundle
# in a synced folder (~/Documents) at any moment, even between `xattr -c` and codesign. So sign a
# copy outside the project, then put the signed bundle back.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --noextattr --norsrc "$APP" "$STAGE/$APP_NAME.app"
codesign "${CODESIGN_ARGS[@]}" "$STAGE/$APP_NAME.app"
rm -rf "$APP"
ditto "$STAGE/$APP_NAME.app" "$APP"
echo "Built $APP ($CONFIG) $VERSION_LABEL, signed with: $IDENTITY"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature)=' || true
