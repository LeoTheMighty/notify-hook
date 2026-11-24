#!/bin/bash
# Rebuilds AllowShowNotifier.app's executable from src/main.swift and signs the
# bundle with a real "Apple Development" identity from the login keychain.
#
# The signed bundle IS committed, so a Mac without Xcode or a signing identity
# (e.g. a managed work Mac) can just clone and run ./setup.sh. Run this only on
# a Mac that has the identity, after editing src/main.swift or Info.plist, then
# commit helper/AllowShowNotifier.app. The binary is universal (arm64 + x86_64,
# macOS 11+), timestamped by Apple, and carries Contents/Resources/source.sha256
# so setup.sh can tell whether the committed build matches the source.
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

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal, macOS 11+ (the first arm64 release; UserNotifications needs 10.14),
# so the committed build runs on any Mac -- swiftc's default target is this
# machine's arch and OS. Compiled beside the live binary and renamed over it:
# helpers waiting on open cards are running the old file, and rewriting it in
# place would kill them.
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos11.0" src/main.swift -o "$TMPD/$arch"
done
NEW="$APP/Contents/MacOS/.AllowShowNotifier.new"
lipo -create "$TMPD/arm64" "$TMPD/x86_64" -output "$NEW"
mv -f "$NEW" "$APP/Contents/MacOS/AllowShowNotifier"
# What this build was made from (sealed by the signature below).
./source-hash.sh > "$APP/Contents/Resources/source.sha256"

echo "Signing with: $SIGN_NAME${SIGN_ID:+ [$SIGN_ID]}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
elif ! codesign --force --deep --timestamp --sign "$SIGN_ID" "$APP"; then
  # Apple's timestamp server needs the network; the signature is valid without
  # one, it just can't prove when it was made once the certificate expires.
  printf 'build.sh: WARNING: timestamping failed (offline?); signing without a secure timestamp.\n' >&2
  codesign --force --deep --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

# (Captured first: `codesign | grep -q` under pipefail misreports a match.)
SIG_INFO=$(codesign -dvv "$APP" 2>&1)
if [ "$SIGN_ID" != "-" ] && ! grep -q '^Authority=' <<<"$SIG_INFO"; then
  die "codesign produced an ad-hoc signature even though identity '$SIGN_NAME' was requested"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Built $APP/Contents/MacOS/AllowShowNotifier ($(lipo -archs "$APP/Contents/MacOS/AllowShowNotifier"))"
grep -E '^(Authority=Apple|TeamIdentifier|Timestamp)' <<<"$SIG_INFO"
echo "Commit it: git add helper/AllowShowNotifier.app && git commit"
