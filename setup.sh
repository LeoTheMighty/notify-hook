#!/bin/bash
# setup.sh -- set up, or diagnose, notify-hook on this Mac. Safe to re-run any
# time: it checks every step of README.md "Setup steps" in order, fixes what it
# can by itself (builds/signs the helper, asks macOS for notification
# permission, opens the right System Settings page), and prints the exact click
# for what only you can do.
#
#   ./setup.sh                 check (and build / authorize as needed)
#   ./setup.sh --install-hook  also make ~/.claude/hooks/notify.sh run this
#                              checkout (the old file is kept as .pre-helper)
#
# Exit status: 0 when every required step passes.

# shellcheck disable=SC2088  # "~/..." in messages is display text, not a path
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
REPO="$PWD"
APP="$REPO/helper/AllowShowNotifier.app"
BIN="$APP/Contents/MacOS/AllowShowNotifier"
BUNDLE_ID="com.leobelyi.notify-hook.allowshownotifier"
LIVE_HOOK="$HOME/.claude/hooks/notify.sh"
SETTINGS="$HOME/.claude/settings.json"
PROBLEM_DIR="${TMPDIR:-/tmp}/claude-notify-state/problems"
INSTALL_HOOK=0
[ "${1:-}" = "--install-hook" ] && INSTALL_HOOK=1

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'; else G=; R=; D=; N=; fi
FAILED=()
step() { printf '\n%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; FAILED+=("$CURRENT"); }
info() { printf '  %s·%s %s\n' "$D" "$N" "$*"; }
fix()  { printf '    → %s\n' "$*"; }
clear_problem() { rm -f "$PROBLEM_DIR/$1" "$PROBLEM_DIR/$1.shown"; }

# ------------------------------------------------------------------------- 1
CURRENT="1 (signing identity)"
step "1. Code-signing identity (only needed to rebuild the helper)"
ID_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"Apple Development: ' | head -n 1)
if [ -n "$ID_LINE" ]; then
  ok "$(printf '%s' "$ID_LINE" | sed -E 's/^[^"]*"(.*)".*$/\1/')"
else
  ok "none, which is fine: this checkout ships a signed helper (step 2)"
  info "to rebuild it yourself you'd need one: Xcode → Settings → Accounts → + (any Apple ID) → Personal Team → Manage Certificates… → + → Apple Development"
fi

# ------------------------------------------------------------------------- 2
CURRENT="2 (helper)"
step "2. Helper signed and matching the source"
# helper_problem: why the bundle can't be used as-is ("" when it can).
helper_problem() {
  local sig
  [ -x "$BIN" ] || { echo "missing"; return; }
  sig=$(codesign -dvv "$APP" 2>&1)
  grep -q '^Authority=' <<<"$sig" || { echo "ad-hoc signed or unsigned"; return; }
  codesign --verify --strict "$APP" >/dev/null 2>&1 || { echo "its signature doesn't verify (a file in it was changed)"; return; }
  [ "$(cat "$APP/Contents/Resources/source.sha256" 2>/dev/null)" = "$(helper/source-hash.sh)" ] \
    || { echo "built from a different helper/src/main.swift or Info.plist than this checkout"; return; }
}
# A downloaded (not cloned) copy carries quarantine, and Gatekeeper refuses to
# run an un-notarized app ("could not be opened") -- so clear it before the
# helper runs at all. git clone/pull never sets it.
if [ -d "$APP" ] && grep -q com.apple.quarantine <<<"$(/usr/bin/xattr -r "$APP" 2>/dev/null)"; then
  /usr/bin/xattr -dr com.apple.quarantine "$APP" && info "removed the download quarantine flag (Gatekeeper would block it)"
fi
WHY=$(helper_problem)
if [ -n "$WHY" ] && [ -n "$ID_LINE" ]; then
  info "$WHY -- rebuilding with helper/build.sh"
  if OUT=$(helper/build.sh 2>&1); then
    WHY=$(helper_problem)
    [ -z "$WHY" ] && info "rebuilt; commit it so Macs without an identity get it: git add helper/AllowShowNotifier.app && git commit"
  else
    bad "helper/build.sh failed:"
    printf '%s\n' "$OUT" | tail -n 15 | sed 's/^/      /'
    WHY="build failed"
  fi
fi
if [ -z "$WHY" ]; then
  SIG=$(codesign -dvv "$APP" 2>&1)
  ok "signed by $(sed -n 's/^Authority=//p' <<<"$SIG" | head -n 1), team $(sed -n 's/^TeamIdentifier=//p' <<<"$SIG"), $(lipo -archs "$BIN" 2>/dev/null), matches the source"
  # So System Settings shows it as "Claude Code" with its icon.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1
  clear_problem unusable
elif [ "$WHY" != "build failed" ]; then
  bad "the committed helper is $WHY, and this Mac has no signing identity to rebuild it"
  fix "git pull (the committed build should match the source), or rebuild on a Mac with the identity and commit helper/AllowShowNotifier.app"
fi

# ------------------------------------------------------------------------- 3
CURRENT="3 (notifications allowed)"
step "3. Notifications allowed for \"Claude Code\" (the helper's name in System Settings)"
STATUS=""
if [ -x "$BIN" ]; then
  STATUS=$("$BIN" status 2>/dev/null)
  case "${STATUS%% *}" in
    "")
      bad "the helper didn't run (blocked by Gatekeeper? see step 2)"
      fix "run it once by hand to see why: $BIN status" ;;
    authorized)
      ok "authorized" ;;
    notDetermined)
      info "macOS hasn't asked yet. A \"Claude Code would like to send you notifications\" prompt is appearing now:"
      fix "click Allow -- and leave this running until you have (an unanswered prompt is recorded as denied)"
      "$BIN" authorize >/dev/null 2>&1
      STATUS=$("$BIN" status 2>/dev/null)
      if [ "${STATUS%% *}" = "authorized" ]; then ok "authorized"
      else bad "still ${STATUS%% *}"; fix "System Settings → Notifications → Claude Code → turn on Allow notifications"; fi ;;
    *)
      info "${STATUS%% *}: macOS won't ask again, so it has to be turned on by hand. Opening that Settings page…"
      open "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=$BUNDLE_ID" 2>/dev/null
      fix "System Settings → Notifications → Claude Code → turn on Allow notifications"
      if [ -t 0 ]; then
        info "waiting up to 3 minutes for it…"
        for _ in $(seq 90); do
          STATUS=$("$BIN" status 2>/dev/null)
          [ "${STATUS%% *}" = "authorized" ] && break
          sleep 2
        done
      fi
      if [ "${STATUS%% *}" = "authorized" ]; then ok "authorized"; else bad "not authorized (${STATUS%% *})"; fi ;;
  esac
else
  bad "skipped: no helper (step 2)"
fi
[ "${STATUS%% *}" = "authorized" ] && clear_problem auth

# ------------------------------------------------------------------------- 4
CURRENT="4 (alert style)"
step "4. Alert style"
case "${STATUS##*alertStyle=}" in
  alert)  ok "Persistent: cards stay in the corner until you act" ;;
  banner) info "Temporary: cards slide into Notification Center after a few seconds and wait there (fine)"
          fix "optional, for cards that stay in the corner: System Settings → Notifications → Claude Code → Persistent" ;;
  none)   bad "None: cards never pop up"
          fix "System Settings → Notifications → Claude Code → choose Temporary or Persistent" ;;
  *)      info "unknown (needs step 3)" ;;
esac

# ------------------------------------------------------------------------- 5
CURRENT="5 (Focus)"
step "5. Focus modes let the cards through"
if [ "${STATUS%% *}" = "authorized" ]; then
  START=$(date '+%Y-%m-%d %H:%M:%S')
  PROBE=$("$BIN" probe 2>&1)
  sleep 1
  VERDICTS=$(/usr/bin/log show --start "$START" --info \
      --predicate "process == \"donotdisturbd\" AND eventMessage CONTAINS \"suppression event\" AND eventMessage CONTAINS \"$BUNDLE_ID\"" \
      2>/dev/null | grep -oE 'suppression=[0-9]+')
  if [ "${PROBE%% *}" != "posted" ]; then
    bad "couldn't post a test card: $PROBE"
  elif [ -z "$VERDICTS" ]; then
    ok "a test card was shown, and no Focus is filtering right now"
    fix "if you use Focus modes (e.g. Work), add Claude Code to each: System Settings → Focus → (Focus) → Allowed Notifications → Apps → Add"
  elif grep -qv '^suppression=0$' <<<"$VERDICTS"; then
    bad "your current Focus hid a test card (no banner; Notification Center only)"
    fix "System Settings → Focus → (the Focus that's on) → Allowed Notifications → Apps → Add → Claude Code. Opening Focus settings…"
    open "x-apple.systempreferences:com.apple.Focus-Settings.extension" 2>/dev/null
  else
    ok "a test card got through your current Focus"
    clear_problem focus
  fi
else
  bad "skipped: notifications not allowed (step 3)"
fi

# ------------------------------------------------------------------------- 6
CURRENT="6 (live hook)"
step "6. Claude Code runs this checkout"
WRAPPER="exec $REPO/notify.sh \"\$@\""
if grep -qF "$WRAPPER" "$LIVE_HOOK" 2>/dev/null; then
  ok "~/.claude/hooks/notify.sh runs $REPO/notify.sh"
elif [ "$INSTALL_HOOK" = 1 ]; then
  BACKUP="$LIVE_HOOK.pre-helper"
  [ -e "$BACKUP" ] && BACKUP="$LIVE_HOOK.pre-helper.$(date +%Y%m%d%H%M%S)"
  mkdir -p "$(dirname "$LIVE_HOOK")"
  [ -e "$LIVE_HOOK" ] && cp -p "$LIVE_HOOK" "$BACKUP" && info "old hook saved as $BACKUP"
  printf '#!/bin/bash\n# Claude Code notification hook: runs the notify-hook checkout (one card with\n# real Allow/Show buttons). Installed by %s/setup.sh.\n%s\n' "$REPO" "$WRAPPER" > "$LIVE_HOOK.tmp" \
    && chmod +x "$LIVE_HOOK.tmp" && mv -f "$LIVE_HOOK.tmp" "$LIVE_HOOK" \
    && ok "~/.claude/hooks/notify.sh now runs $REPO/notify.sh"
else
  bad "~/.claude/hooks/notify.sh doesn't run this checkout"
  fix "re-run as ./setup.sh --install-hook (keeps the old file as notify.sh.pre-helper)"
fi
MISSING=$(/usr/bin/python3 - "$SETTINGS" <<'EOF'
import json, sys
try:
    hooks = json.load(open(sys.argv[1])).get("hooks", {})
except Exception:
    hooks = {}
for event, arg in (("PermissionRequest", "permission"), ("Elicitation", "elicitation"), ("Stop", "stop")):
    cmds = [h.get("command", "") for g in hooks.get(event, []) for h in g.get("hooks", [])]
    if not any("notify.sh" in c and c.rstrip().endswith(arg) for c in cmds):
        print(f"{event}:{arg}")
EOF
)
if [ -z "$MISSING" ]; then
  ok "settings.json runs it on PermissionRequest, Elicitation and Stop"
else
  for m in $MISSING; do
    bad "settings.json has no ${m%%:*} hook running notify.sh ${m#*:}"
    fix "add to \"hooks\" in ~/.claude/settings.json: \"${m%%:*}\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"$LIVE_HOOK ${m#*:}\"}]}]"
  done
  info "(Stop is what shows setup problems in your sessions; PermissionRequest/Elicitation post the cards)"
fi

# ------------------------------------------------------------------------ done
echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  printf '%sAll set.%s Permission prompts will arrive as one card with Allow / Show.\n' "$G" "$N"
  exit 0
fi
printf '%sNeeds you:%s step %s. Fix the ✗ items above, then re-run ./setup.sh.\n' "$R" "$N" "$(printf '%s, ' "${FAILED[@]}" | sed 's/, $//')"
exit 1
