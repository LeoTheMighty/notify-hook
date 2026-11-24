#!/bin/bash
# Rebuilds AllowShowNotifier.app's executable from src/main.swift and signs the
# bundle with a real "Apple Development" identity from the login keychain. The
# compiled binary isn't committed (it's machine/arch specific); run this after
# cloning or after editing src/main.swift.
#
# Why a real identity and not ad-hoc (`codesign -s -`): amfid rejects an ad-hoc
# signature for this bundle with
#   AppleMobileFileIntegrityError Code=-423 "The file is adhoc signed or signed
#   by an unknown certificate chain"
# On the managed work Mac the ad-hoc build never got a notification-permission
# prompt; on macOS 26.2 it did despite -423 (see TODO.md), so treat a real
# signature as the safe requirement rather than the proven fix. A free Personal
# Team "Apple Development" certificate (Xcode -> Settings -> Accounts -> Manage
# Certificates) chains to Apple's WWDR root and clears -423. See README.md.
#
# Identity selection, in order:
#   CODESIGN_IDENTITY=<name or SHA-1>   use exactly that identity
#   (unset)                             first "Apple Development:" identity in
#                                       `security find-identity -v -p codesigning`
# If neither yields one, this FAILS -- it never silently falls back to ad-hoc,
# because an ad-hoc build reproduces the -423 problem invisibly. To build an
# ad-hoc binary on purpose (e.g. to reproduce -423), say so explicitly with
# CODESIGN_IDENTITY=- ; notify.sh refuses to use such a build either way.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP="AllowShowNotifier.app"

die() {
  printf 'build.sh: ERROR: %s\n' "$*" >&2
  exit 1
}

# Resolve the identity before compiling, so a missing cert fails fast.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  SIGN_ID="$CODESIGN_IDENTITY"
  SIGN_NAME="$CODESIGN_IDENTITY"
else
  IDENTITIES=$(security find-identity -v -p codesigning 2>&1) \
    || die "\`security find-identity -v -p codesigning\` failed: $IDENTITIES"
  # Lines look like:   1) C60F...3886 "Apple Development: Name (ABCDE12345)"
  LINE=$(printf '%s\n' "$IDENTITIES" | grep -E '^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]{40}[[:space:]]+"Apple Development: ' | head -n 1 || true)
  if [ -z "$LINE" ]; then
    die "no valid \"Apple Development:\" code-signing identity in your keychain.
  \`security find-identity -v -p codesigning\` said:
$(printf '%s\n' "$IDENTITIES" | sed 's/^/    /')
  Get one free: Xcode -> Settings -> Accounts -> + (any Apple ID) -> select the
  Personal Team -> Manage Certificates... -> + -> Apple Development.
  Refusing to fall back to ad-hoc signing (amfid rejects it with -423).
  To build ad-hoc deliberately anyway: CODESIGN_IDENTITY=- $0"
  fi
  # Sign by SHA-1, not by name: a renewed cert leaves two identities with the
  # same name, and codesign rejects an ambiguous name.
  SIGN_ID=$(printf '%s\n' "$LINE" | grep -oE '[0-9A-F]{40}' | head -n 1)
  SIGN_NAME=$(printf '%s\n' "$LINE" | sed -E 's/^[^"]*"(.*)"[[:space:]]*$/\1/')
fi

if [ "$SIGN_ID" = "-" ]; then
  printf 'build.sh: WARNING: ad-hoc signing requested via CODESIGN_IDENTITY=-.\n' >&2
  printf 'build.sh: WARNING: amfid will reject this build (-423) and notify.sh will not use it.\n' >&2
fi

mkdir -p "$APP/Contents/MacOS"
# Compile beside the live binary and rename over it: helpers waiting on open
# cards are running the old file, and rewriting it in place would kill them.
NEW="$APP/Contents/MacOS/.AllowShowNotifier.new"
swiftc -O src/main.swift -o "$NEW"
mv -f "$NEW" "$APP/Contents/MacOS/AllowShowNotifier"

echo "Signing with: $SIGN_NAME${SIGN_ID:+ [$SIGN_ID]}"
codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ "$SIGN_ID" != "-" ] && codesign -dv "$APP" 2>&1 | grep -q '^Signature=adhoc'; then
  die "codesign produced an ad-hoc signature even though identity '$SIGN_NAME' was requested"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Built $APP/Contents/MacOS/AllowShowNotifier"
codesign -dv "$APP" 2>&1
