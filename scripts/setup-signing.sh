#!/bin/sh
# One-time (per machine) setup of a stable code-signing identity for pb-record.
#
# The problem this solves: an ad-hoc signature (`codesign --sign -`) changes the
# code hash on every rebuild, and macOS ties Accessibility grants to that hash —
# so every rebuild re-prompts for permissions. A signature from a *stable*
# identity produces a Designated Requirement based on the certificate + bundle id
# (not the code hash), which TCC honors across every future rebuild. Grant once.
#
# We generate a self-signed code-signing certificate and store it in a dedicated
# keychain whose password we set ourselves — that lets us configure key access
# fully non-interactively (no login-password prompt). The keychain holds nothing
# but this one local-dev cert.
#
# Idempotent: if the identity already exists, this does nothing (re-running must
# NOT regenerate the cert, or the Designated Requirement would change and grants
# would reset). Delete the keychain to start over.
#
# For distribution (a signed, notarized app other people can run without
# warnings) swap this identity for an Apple Developer ID — see build-app.sh.
set -eu

IDENTITY="Playbooks Local Signing"
KC="$HOME/Library/Keychains/playbooks-signing.keychain-db"
KCPASS="playbooks-local"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# NB: `find-identity -v` lists only *trusted* identities and would miss this
# self-signed cert (it's untrusted-but-usable). Plain `find-identity` lists all.
if security find-identity "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ signing identity already set up ($IDENTITY)"
    # Ensure it's in the search list and unlocked (harmless if already so).
    security list-keychains -d user | tr -d '" ' | grep -qxF "$KC" || \
        security list-keychains -d user -s "$LOGIN_KC" "$KC"
    security unlock-keychain -p "$KCPASS" "$KC"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Self-signed cert with the codeSigning extended key usage.
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl req -x509 -new -key "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$IDENTITY/O=Playbooks Dev" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# 2. Bundle into a p12. `-descert` uses 3DES (not RC2-40, which macOS `security`
#    can't import), and a real passphrase avoids the empty-password MAC ambiguity
#    that makes `security import` fail with "MAC verification failed".
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:pbdev -name "$IDENTITY" -descert 2>/dev/null

# 3. Dedicated keychain with a password we control.
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"            # disable auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P pbdev -A -T /usr/bin/codesign

# 4. Authorize codesign to use the key without a GUI prompt. This is the step
#    that needs a keychain password — and because the keychain is ours, we have it.
security set-key-partition-list -S apple-tool:,apple:,codesign:,unsigned: \
    -s -k "$KCPASS" "$KC" >/dev/null

# 5. Put it on the search path so codesign finds the identity by name.
security list-keychains -d user -s "$LOGIN_KC" "$KC"

echo "✓ created stable signing identity: $IDENTITY"
echo "  keychain: $KC"
echo "  Grants given to the signed pb-record.app now persist across rebuilds."
