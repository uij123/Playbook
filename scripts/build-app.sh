#!/bin/sh
# Assemble pb-record into a signed .app bundle.
#
# Why this exists: on-device voice (Microphone + Speech Recognition) is gated by
# macOS TCC, which attributes the request to the *responsible app*. A bare CLI
# spawned from a terminal has no bundle identity of its own, so TCC blames the
# terminal — and SIGABRTs pb-record the instant it touches speech. Packaged as a
# standalone .app and launched on its own (via `open` or Finder), pb-record
# becomes its own TCC subject and can legitimately request mic/speech.
#
# The trade-off: a standalone app identity does NOT inherit the terminal's
# Accessibility grant. The .app must be granted Accessibility, Screen Recording,
# Microphone, and Speech Recognition itself, once, in System Settings. That is
# the normal distribution model for a tool that needs both a global event tap
# and the microphone.
#
# Usage: scripts/build-app.sh   (run from repo root, after `make native`)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/native/.build/release/pb-record"
PLIST="$ROOT/native/Support/pb-record-Info.plist"

# Install to a PERMANENT path and update in place. macOS ties an Accessibility
# grant to the app at a specific path; wiping and recreating the bundle (even at
# the same path, even with a stable signature) can read as a new app and drop the
# grant — the "keeps asking, but it's already granted" loop. A fixed install
# location whose Contents we refresh in place keeps the grant stable. `pb record`
# and the docs reference this path.
APP="$HOME/Applications/Playbooks/pb-record.app"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built — run \`make native\` first" >&2
    exit 1
fi

# Update in place: keep the bundle directory (and thus its TCC identity/path),
# only refresh the binary and plist. Do NOT `rm -rf` the whole .app.
mkdir -p "$APP/Contents/MacOS"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/pb-record"

# Prefer the stable self-signed identity from setup-signing.sh: its Designated
# Requirement is identity-based, so TCC grants survive every rebuild. Fall back to
# ad-hoc only if setup hasn't been run (grants will then reset on each rebuild).
# For distribution, replace IDENTITY with your "Developer ID Application: …" and
# add --options runtime, then notarize the .app.
IDENTITY="Playbooks Local Signing"
KC="$HOME/Library/Keychains/playbooks-signing.keychain-db"
# Plain `find-identity` (not `-v`) so the untrusted-but-usable self-signed cert
# is detected; codesign signs with it fine despite the untrusted status.
if security find-identity "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "playbooks-local" "$KC" 2>/dev/null || true
    codesign --force --sign "$IDENTITY" --keychain "$KC" \
        --identifier dev.playbooks.pb-record "$APP"
    SIGNED_WITH="$IDENTITY (grants persist across rebuilds)"
else
    echo "note: stable signing identity not found — run 'make signing-setup' once"
    echo "      so macOS permissions stop resetting. Falling back to ad-hoc."
    codesign --force --sign - --identifier dev.playbooks.pb-record "$APP"
    SIGNED_WITH="ad-hoc (grants reset on each rebuild)"
fi

# Validate the result rather than trusting the copy.
codesign --verify --strict "$APP"
# The source plist must carry the usage descriptions...
if ! grep -q NSSpeechRecognitionUsageDescription "$APP/Contents/Info.plist"; then
    echo "error: Info.plist is missing NSSpeechRecognitionUsageDescription" >&2
    exit 1
fi
# ...and the linker must have embedded a non-empty __info_plist section, which is
# the copy TCC actually reads for an unbundled-launch. (otool renders it as
# byte-swapped hex words, so we check presence/size, not decoded text.)
if [ "$(otool -s __TEXT __info_plist "$APP/Contents/MacOS/pb-record" | wc -l)" -lt 3 ]; then
    echo "error: __info_plist section missing or empty in the binary" >&2
    exit 1
fi

echo "✓ built $APP"
echo "  signed with: $SIGNED_WITH"
echo ""
echo "To enable voice narration, grant the app these in System Settings →"
echo "Privacy & Security (they attribute to the app, not your terminal):"
echo "  • Accessibility        (record input / replay)"
echo "  • Screen Recording     (per-click screenshots)"
echo "  • Microphone + Speech Recognition (voice)"
echo ""
echo "First run — trigger the grant prompts, then add the app in each pane:"
echo "  open $APP --args --out /tmp/pb-grant-check --voice"
