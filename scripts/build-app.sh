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
APP="$ROOT/native/.build/pb-record.app"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not built — run \`make native\` first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/pb-record"

# Ad-hoc signature (identity "-"): enough to give the bundle a stable TCC identity
# on the local machine. A real distribution build would sign with a Developer ID
# and notarize; that is a P1 release task, not needed for local voice testing.
codesign --force --sign - --identifier dev.playbooks.pb-record \
    --options runtime "$APP" >/dev/null 2>&1 || \
    codesign --force --sign - --identifier dev.playbooks.pb-record "$APP"

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
echo "  identity: dev.playbooks.pb-record (ad-hoc signed)"
echo ""
echo "To enable voice narration, grant the app these in System Settings →"
echo "Privacy & Security (they attribute to the app, not your terminal):"
echo "  • Accessibility        (record input / replay)"
echo "  • Screen Recording     (per-click screenshots)"
echo "  • Microphone + Speech Recognition (voice)"
echo ""
echo "First run — trigger the grant prompts, then add the app in each pane:"
echo "  open $APP --args --out /tmp/pb-grant-check --voice"
