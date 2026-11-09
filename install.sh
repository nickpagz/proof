#!/bin/sh
# Proof installer. Downloads the latest release, checks it, and puts it in Applications.
# Run it again any time to upgrade an existing copy.
#
#   curl -fsSL https://raw.githubusercontent.com/nickpagz/proof/trunk/install.sh | sh
#
# Optional environment:
#   PROOF_INSTALL_DIR   folder for Proof.app. Default: wherever it is already installed,
#                           else /Applications, else ~/Applications
#   PROOF_FEED          another latest.json, for trying a release before it is published
#   PROOF_REINSTALL=1   reinstall even when this version is already there
#
# What it checks: the archive's SHA-256 and size against the release manifest, that the archive
# holds exactly one validly signed Proof.app of the advertised version, and that the Mac can
# run it. The manifest's Ed25519 signature is verified by the app itself from the first self-update
# on; this first install trusts GitHub over TLS.
#
# Everything lives in main(), so a download cut off halfway runs nothing.
main() {
    set -eu
    REPO="nickpagz/proof"
    BUNDLE_ID="io.github.nickpagz.proof"
    FEED="${PROOF_FEED:-https://github.com/$REPO/releases/latest/download/latest.json}"
    PLIST=/usr/libexec/PlistBuddy

    say() { printf '%s\n' "$*"; }
    die() { printf 'Proof installer: %s\n' "$*" >&2; exit 1; }
    plist() { "$PLIST" -c "Print :$2" "$1" 2>/dev/null; }
    json() { /usr/bin/plutil -extract "$2" raw -o - -- "$1" 2>/dev/null; }

    [ "$(id -u)" -ne 0 ] || die "don't run this with sudo or as root; install as the user who will use Proof."
    [ "$(uname -s)" = "Darwin" ] || die "Proof is a Mac app."
    [ "$(uname -m)" = "arm64" ] || die "Proof needs a Mac with Apple silicon."
    MACOS="$(sw_vers -productVersion)"
    case "$MACOS" in
        [0-9].*|1[0-9].*|2[0-5].*) die "Proof needs macOS 26 or newer; this Mac runs $MACOS." ;;
    esac
    command -v curl >/dev/null || die "curl is missing."

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/proof-install.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    say "Checking the latest Proof release..."
    HTTP="$(curl -sSL -o "$TMP/latest.json" -w '%{http_code}' "$FEED" || true)"
    case "$HTTP" in
        200) ;;
        404) die "no public release is available yet ($FEED)." ;;
        *) die "couldn't fetch the release info (HTTP ${HTTP:-?} from $FEED)." ;;
    esac
    json "$TMP/latest.json" payload | /usr/bin/base64 -d > "$TMP/payload.json" 2>/dev/null \
        || die "the release info is not in the expected format."
    VERSION="$(json "$TMP/payload.json" version)"
    MIN_OS="$(json "$TMP/payload.json" minimumSystemVersion)"
    ZIP_NAME="$(json "$TMP/payload.json" zip.name)"
    ZIP_URL="$(json "$TMP/payload.json" zip.url)"
    ZIP_SHA="$(json "$TMP/payload.json" zip.sha256)"
    ZIP_SIZE="$(json "$TMP/payload.json" zip.size)"
    [ "$(json "$TMP/payload.json" bundleID)" = "$BUNDLE_ID" ] || die "the release info describes a different app."
    [ -n "$VERSION" ] && [ -n "$ZIP_NAME" ] && [ -n "$ZIP_SHA" ] && [ -n "$ZIP_SIZE" ] || die "the release info is incomplete."
    if [ -n "${PROOF_FEED:-}" ]; then
        # A custom feed serves the zip next to its latest.json, like the app's own updater.
        ZIP_URL="${FEED%/*}/$ZIP_NAME"
    fi
    case "$ZIP_NAME" in */*|*' '*|'') die "the release names an unexpected archive." ;; esac
    MIN_MAJOR="${MIN_OS%%.*}"; MAC_MAJOR="${MACOS%%.*}"
    [ "${MAC_MAJOR:-0}" -ge "${MIN_MAJOR:-26}" ] || die "Proof $VERSION needs macOS $MIN_OS or newer; this Mac runs $MACOS."

    if [ -n "${PROOF_INSTALL_DIR:-}" ]; then
        DEST_DIR="$PROOF_INSTALL_DIR"
    elif [ -d /Applications/Proof.app ]; then
        DEST_DIR=/Applications
    elif [ -d "$HOME/Applications/Proof.app" ]; then
        DEST_DIR="$HOME/Applications"
    elif [ -w /Applications ]; then
        DEST_DIR=/Applications
    else
        DEST_DIR="$HOME/Applications"
    fi
    mkdir -p "$DEST_DIR" 2>/dev/null || die "can't create $DEST_DIR."
    [ -w "$DEST_DIR" ] || die "can't write to $DEST_DIR. Set PROOF_INSTALL_DIR to a folder you own."
    DEST="$DEST_DIR/Proof.app"

    if [ -d "$DEST" ]; then
        CURRENT="$(plist "$DEST/Contents/Info.plist" CFBundleShortVersionString || echo unknown)"
        if [ "$CURRENT" = "$VERSION" ] && [ "${PROOF_REINSTALL:-0}" != 1 ]; then
            say "Proof $VERSION is already installed at $DEST."
            /usr/bin/open "$DEST"
            exit 0
        fi
        say "Upgrading Proof ${CURRENT} to ${VERSION} in ${DEST_DIR}"
    else
        say "Installing Proof ${VERSION} into ${DEST_DIR}"
    fi

    say "Downloading ${ZIP_NAME}..."
    curl -fL -# -o "$TMP/$ZIP_NAME" "$ZIP_URL" || die "the download failed ($ZIP_URL)."
    ACTUAL_SIZE="$(/usr/bin/stat -f %z "$TMP/$ZIP_NAME")"
    [ "$ACTUAL_SIZE" = "$ZIP_SIZE" ] || die "the download is $ACTUAL_SIZE bytes, not the $ZIP_SIZE the release promised. Nothing was installed."
    if [ -x /usr/bin/shasum ]; then
        ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$TMP/$ZIP_NAME" | cut -d' ' -f1)"
    else
        ACTUAL_SHA="$(openssl dgst -sha256 "$TMP/$ZIP_NAME" | awk '{print $NF}')"
    fi
    [ "$ACTUAL_SHA" = "$ZIP_SHA" ] || die "the download's checksum doesn't match the release. Nothing was installed."

    # ditto keeps the code signature intact; unzip can break it.
    mkdir "$TMP/unpacked"
    /usr/bin/ditto -x -k "$TMP/$ZIP_NAME" "$TMP/unpacked" || die "couldn't unpack the download."
    NEW="$TMP/unpacked/Proof.app"
    [ -d "$NEW" ] || die "the archive doesn't contain Proof.app."
    [ "$(ls -A "$TMP/unpacked" | wc -l | tr -d ' ')" = 1 ] || die "the archive contains more than Proof.app."
    /usr/bin/codesign --verify --deep --strict "$NEW" 2>/dev/null || die "the downloaded app's code signature is invalid. Nothing was installed."
    [ "$(plist "$NEW/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "the downloaded app is not Proof."
    [ "$(plist "$NEW/Contents/Info.plist" CFBundleShortVersionString)" = "$VERSION" ] || die "the downloaded app is not version $VERSION."
    # curl doesn't set the quarantine flag, but clear it in case this archive came another way.
    /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

    if /usr/bin/pgrep -xq Proof; then
        say "Quitting the running Proof..."
        /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        i=0
        while /usr/bin/pgrep -xq Proof && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
        /usr/bin/pgrep -xq Proof && die "Proof is still running. Quit it (finish any recording first) and run the installer again."
    fi

    OLD=""
    if [ -d "$DEST" ]; then
        OLD="$DEST_DIR/.Proof-old-$$.app"
        mv "$DEST" "$OLD" || die "couldn't move the existing copy aside."
    fi
    if /usr/bin/ditto "$NEW" "$DEST" && /usr/bin/codesign --verify --deep --strict "$DEST" 2>/dev/null; then
        [ -z "$OLD" ] || rm -rf "$OLD"
    else
        rm -rf "$DEST"
        [ -z "$OLD" ] || mv "$OLD" "$DEST"
        die "installing into $DEST_DIR failed; the previous copy was put back."
    fi
    touch "$DEST"
    /usr/bin/open "$DEST"

    say ""
    say "Installed Proof ${VERSION} to ${DEST}."
    say "Look for the Proof icon in your menu bar. The first time, macOS asks for Screen Recording"
    say "permission (System Settings > Privacy & Security > Screen & System Audio Recording). Allow it,"
    say "then quit and reopen Proof. Future updates arrive inside the app."
}

main "$@"
