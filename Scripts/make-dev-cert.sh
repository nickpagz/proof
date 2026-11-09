#!/bin/bash
# Creates a self-signed code-signing certificate named "Proof Dev" in the login keychain.
# Signing every build with it keeps the code identity stable, so macOS remembers the
# Screen Recording, Microphone and Camera grants across rebuilds. Run once, then:
#   make build
# You may be asked for your login password when the key is imported or trusted.
set -euo pipefail
NAME="${1:-Proof Dev}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "A certificate named \"$NAME\" already exists in your keychain."
    echo "Delete it in Keychain Access first if you want to recreate it."
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1
# macOS's `security import` only understands the older PKCS#12 algorithms; OpenSSL 3 and
# LibreSSL default to AES + SHA-256, which fails with "MAC verification failed".
openssl pkcs12 -export -out "$TMP/identity.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:proof \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P proof -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing in the user trust domain (prompts for your password).
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
echo "Created \"$NAME\". Scripts/bundle.sh picks it up by itself; rebuild with make build."
security find-identity -v -p codesigning | grep "$NAME" || true
