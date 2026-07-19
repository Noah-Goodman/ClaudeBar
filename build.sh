#!/bin/zsh
# Build the debug binary and sign it with a stable identity.
#
# The signature matters: ClaudeBar reads the "Claude Code-credentials" keychain
# item, and the keychain's "Always Allow" grant is tied to the app's signing
# identity. An ad-hoc signed binary gets a new identity on every rebuild, which
# re-triggers the permission prompt each time. Signing with a real certificate
# keeps the identity stable, so one "Always Allow" lasts across rebuilds.
#
# The identity is read from release/signing-identity (untracked) or the
# CODESIGN_IDENTITY environment variable. Without either, the build is ad-hoc
# signed and keychain prompts will recur on every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f release/signing-identity ]]; then
    IDENTITY=$(head -1 release/signing-identity)
fi

swift build "$@"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" .build/debug/ClaudeBar
    echo "Signed .build/debug/ClaudeBar with: $IDENTITY"
else
    echo "warning: no signing identity (release/signing-identity or CODESIGN_IDENTITY); ad-hoc build will re-prompt for keychain access" >&2
fi
