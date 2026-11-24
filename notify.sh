#!/bin/bash
# Desktop notification for Claude Code hook events.
# Usage: notify.sh <permission|elicitation|stop>
#
# Notifies only when Claude needs you: a permission request or an interview
# question. `notify.sh stop` (every turn end) posts nothing; it only reports
# setup problems -- see "Setup problems" below.
#
# Posts real, persistent macOS Notification Center items instead of a
# `display alert ... giving up after N` modal. A notification you don't act on
# just sits in Notification Center until you dismiss it -- it is never silently
# lost to a timeout. (`osascript display notification` was ruled out: it has no
# click handler at all, so it can't drive Allow/Show. See README.md.)
#
# Each event is ONE card from helper/AllowShowNotifier.app with real "Allow"
# and "Show" buttons ("Show" only, for elicitation). A detached waiter
# (`notify.sh __await_helper__`) runs `AllowShowNotifier post ...`, which
# blocks until the card is acted on and prints one word -- ALLOW / SHOW /
# DISMISS -- and the waiter turns ALLOW / SHOW into a
# `notify.sh __dispatch__ <state> allow|view` call. Setup (signing, enabling
# notifications, Focus): README.md "Setup steps".
#
# There is deliberately no fallback (an earlier terminal-notifier two-card
# version was removed): when the helper can't post -- missing, ad-hoc signed or
# unsigned, notifications off for it -- nothing is shown, and notify.log says
# why (`helper unusable: ...` / `helper showed nothing: ...`).
#
# Setup problems: when an event finds the helper unusable, notifications off
# for it, the helper failing, or a Focus mode hiding its cards (read from
# donotdisturbd's verdict in the unified log), it records a one-line fix under
# $STATE_DIR/problems/. The next `notify.sh stop` shows those fixes in the
# Claude Code session as a Stop-hook systemMessage ("Stop says: ..."), at most
# once an hour per problem, pointing at setup.sh. (Claude Code shows a Stop
# hook's systemMessage; it does not show one from PermissionRequest -- checked
# on 2.1.331.) A later event that works clears its problem.
#
# xirp tabs are tmux panes, not Terminal.app tabs. When this hook runs inside a
# tmux session named `xirp-<uuid>` it targets that tab directly:
#   - "Show" focuses it with the xirp://open-session deep link, which raises
#     the Xirp window (main process app.focus({steal:true})) and selects the
#     tab.
#   - "Allow" is delivered with `tmux send-keys` to the asking PANE, so it can
#     never land in whichever tab happens to be visible.
#   - Leaving the notification alone does nothing at all -- it just sits there.
# Outside xirp it falls back to the old Terminal/iTerm2/Warp/VS Code behaviour.
#
# Env:
#   CLAUDE_NOTIFY_DEBUG=0            stop logging to notify.log (next to this script)
#   CLAUDE_NOTIFY_HELPER_APP=<path>  helper bundle (default: helper/AllowShowNotifier.app
#                                    next to this script)
#   CLAUDE_NOTIFY_FOCUS_CHECK=0      don't check whether a Focus mode hid a card

PY=/usr/bin/python3
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$HOOK_DIR/$(basename "${BASH_SOURCE[0]}")"
LOG="$HOOK_DIR/notify.log"
STATE_DIR="${TMPDIR:-/tmp}/claude-notify-state"
HELPER_APP="${CLAUDE_NOTIFY_HELPER_APP:-$HOOK_DIR/helper/AllowShowNotifier.app}"
HELPER_BIN="$HELPER_APP/Contents/MacOS/AllowShowNotifier"
BUNDLE_ID="com.leobelyi.notify-hook.allowshownotifier"
PROBLEM_DIR="$STATE_DIR/problems"

log() {
  [ "${CLAUDE_NOTIFY_DEBUG:-1}" = "1" ] || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${EVENT:-dispatch}" "$*" >> "$LOG"
  # keep the log small
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 400 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# ----------------------------------------------------------- setup problems

# record_problem <kind> <one-line fix>   (kinds: unusable auth error focus)
record_problem() {
  mkdir -p "$PROBLEM_DIR" && printf '%s\n' "$2" > "$PROBLEM_DIR/$1"
  log "problem[$1] recorded: $2"
}

# clear_problem <kind>
clear_problem() {
  [ -f "$PROBLEM_DIR/$1" ] || return 0
  rm -f "$PROBLEM_DIR/$1" "$PROBLEM_DIR/$1.shown"
  log "problem[$1] cleared"
}

# report_problems: print a Stop-hook JSON systemMessage with every recorded
# problem not already shown in the last hour; print nothing when there's none.
report_problems() {
  local f msgs=()
  for f in "$PROBLEM_DIR"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.shown) continue ;; esac
    [ -n "$(find "$f.shown" -mmin -60 2>/dev/null)" ] && continue
    msgs+=("$(cat "$f")")
    touch "$f.shown"
  done
  [ "${#msgs[@]}" -gt 0 ] || return 0
  log "showing ${#msgs[@]} setup problem(s) in the session"
  "$PY" -c 'import json, sys
print(json.dumps({"systemMessage": " ".join(sys.argv[2:]) + " Check every setup step: " + sys.argv[1]}))' \
    "$HOOK_DIR/setup.sh" "${msgs[@]}"
}

# focus_check <since "YYYY-mm-dd HH:MM:SS"> [<until>]
# donotdisturbd logs a verdict for each card while a Focus is on (observed:
# "... suppression event: bundleIdentifier=<id> suppression=<n>", 0 = shown,
# nonzero = hidden). Any hidden card records the "focus" problem; all shown
# clears it; no verdict (typically: no Focus on) changes nothing.
focus_check() {
  local verdicts
  verdicts=$(/usr/bin/log show --start "$1" ${2:+--end "$2"} --info \
      --predicate "process == \"donotdisturbd\" AND eventMessage CONTAINS \"suppression event\" AND eventMessage CONTAINS \"$BUNDLE_ID\"" \
      2>/dev/null | grep -oE 'suppression=[0-9]+')
  [ -n "$verdicts" ] || return 0
  if printf '%s\n' "$verdicts" | grep -qv '^suppression=0$'; then
    record_problem focus "notify-hook: a Focus mode is hiding Claude Code's permission cards (no banner; they only land in Notification Center). Fix: System Settings → Focus → (the Focus you're in) → Allowed Notifications → Apps → add Claude Code."
  else
    clear_problem focus
  fi
}

# ------------------------------------------------------------------ posting

# helper_usable: 0 when the helper can be launched for this event; else 1 with
# the reason in HELPER_WHY. Cheap and never prompts: whether notifications are
# actually enabled for the helper is answered by the helper itself at post
# time (it prints UNAUTHORIZED:<status>).
helper_usable() {
  HELPER_WHY=""
  if [ ! -x "$HELPER_BIN" ]; then
    HELPER_WHY="no helper at $HELPER_BIN (run helper/build.sh)"
    return 1
  fi
  # Ad-hoc (`codesign -s -`) and unsigned builds have no Authority= line; amfid
  # rejects ad-hoc with -423, and on the managed work Mac that meant no prompt.
  # (-dvv, not -dv: plain -dv never prints Authority= lines, even when signed.)
  if ! codesign -dvv "$HELPER_APP" 2>&1 | grep -q '^Authority='; then
    HELPER_WHY="helper is ad-hoc signed or unsigned (run helper/build.sh)"
    return 1
  fi
  if ! codesign --verify --strict "$HELPER_APP" >/dev/null 2>&1; then
    HELPER_WHY="helper signature does not verify (changed after signing? run helper/build.sh)"
    return 1
  fi
  if [ ! -x "$PY" ]; then
    HELPER_WHY="no $PY to detach the helper waiter"
    return 1
  fi
  return 0
}

# helper_launch <state_file> <permission|elicitation> <label> <message>
# Starts `__await_helper__` in its own session (setsid) with signals it could
# catch from the tab ignored and no inherited fds: it has to outlive this hook
# process, and must not hold Claude Code's hook pipes open while it waits.
helper_launch() {
  (
    trap '' HUP INT
    exec "$PY" -c 'import os, sys; os.setsid(); os.execv("/bin/bash", ["/bin/bash"] + sys.argv[1:])' \
      "$SCRIPT_PATH" __await_helper__ "$@"
  ) </dev/null >/dev/null 2>&1 &
}

# post_event <permission|elicitation> <label> <message> <state_file>
post_event() {
  if helper_usable; then
    clear_problem unusable
    helper_launch "$4" "$1" "$2" "$3"
    log "helper launched"
  else
    log "helper unusable: $HELPER_WHY -- nothing posted"
    record_problem unusable "notify-hook can't post permission cards: $HELPER_WHY."
  fi
}

# ------------------------------------------------------------------ dispatch
#
# This is what the helper waiter (`__await_helper__`, below) calls back into
# when a card is clicked, long after the original `notify.sh permission`
# process (and its env/stdin) is gone. All the state a click needs (pane, xirp
# session id, legacy app/tty, the digit to send) is written to a small
# shell-sourceable state file at post time, and the click just sources it.
#
# Usage: notify.sh __dispatch__ <state-file> <allow|view>
if [ "$1" = "__dispatch__" ]; then
  STATE_FILE="$2"
  ACTION="$3"

  if [ ! -f "$STATE_FILE" ]; then
    log "dispatch: missing state file $STATE_FILE"
    exit 0
  fi
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  log "dispatch action=$ACTION pane='${PANE:-}' xirp_sid='${XIRP_SID:-}' state=$STATE_FILE"

  # True when the asking pane is still showing a Claude Code choice prompt.
  # See the long comment this carried in the `display alert` version: a false
  # positive is cheap (a stray digit lands in the composer where it's visible),
  # a false negative silently eats the click, so this errs toward sending.
  pane_awaiting_choice() {
    [ -n "$PANE" ] || return 1
    local tail_text opts
    tail_text=$(tmux capture-pane -p -t "$PANE" -S -25 2>/dev/null) || return 1
    opts=$(printf '%s' "$tail_text" | grep -cE '^[^0-9]*[12]\.[[:space:]]')
    if [ "${opts:-0}" -lt 2 ]; then
      log "guard: no option list in pane $PANE; tail: $(printf '%s' "$tail_text" \
        | grep -vE '^[[:space:]]*$' | tail -4 | tr '\n' '|')"
      return 1
    fi
    return 0
  }

  do_focus() {
    if [ -n "$XIRP_SID" ]; then
      open "xirp://local/?action=open-session&sessionId=$XIRP_SID"
      log "focus xirp $XIRP_SID"
      return
    fi
    if [ "$APP_NAME" = "Terminal" ]; then
      osascript <<EOF
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$CLAUDE_TTY" then
        set selected of t to true
        set index of w to 1
      end if
    end repeat
  end repeat
  activate
end tell
EOF
    else
      osascript -e "tell application \"$APP_NAME\" to activate"
    fi
    log "focus $APP_NAME"
  }

  do_answer() {
    if [ -n "$PANE" ]; then
      if pane_awaiting_choice; then
        tmux send-keys -t "$PANE" -l "$DIGIT" 2>/dev/null
        log "send-keys -t $PANE '$DIGIT'"
      else
        log "send-keys skipped: pane $PANE no longer prompting; focusing instead"
        do_focus
      fi
      return
    fi
    # Legacy: activate the terminal and type into it.
    if [ "$APP_NAME" = "Terminal" ]; then
      osascript <<EOF
set prevApp to path to frontmost application as text
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$CLAUDE_TTY" then
        set selected of t to true
        set index of w to 1
      end if
    end repeat
  end repeat
  activate
end tell
tell application "System Events"
  tell process "Terminal"
    keystroke "$DIGIT"
  end tell
end tell
activate application prevApp
EOF
    else
      osascript <<EOF
set prevApp to path to frontmost application as text
tell application "$APP_NAME" to activate
tell application "System Events"
  tell process "$APP_NAME"
    keystroke "$DIGIT"
  end tell
end tell
activate application prevApp
EOF
    fi
    log "keystroke $DIGIT -> $APP_NAME"
  }

  case "$ACTION" in
    allow) do_answer ;;
    view)  do_focus ;;
    *)     log "dispatch: unknown action '$ACTION'" ;;
  esac
  exit 0
fi

# ------------------------------------------------------------- helper waiter
#
# One per helper card, detached by helper_launch(). Posts the card through
# AllowShowNotifier, blocks until it is acted on, and turns the helper's one
# stdout line into a `__dispatch__` call -- so do_answer()/do_focus() above are
# the only click handlers.
#
# Usage: notify.sh __await_helper__ <state-file> <permission|elicitation> <label> <message>
if [ "$1" = "__await_helper__" ]; then
  STATE_FILE="$2"
  EVENT="$3"
  LABEL="$4"
  MSG="$5"
  ERR_FILE="$STATE_FILE.helper-err"
  case "$EVENT" in
    permission) TITLE="Permission needed" ;;
    *)          TITLE="Claude is waiting for you" ;;
  esac

  # Did a Focus hide it? Checked a few seconds after posting, at most every 10
  # minutes -- or every card while a Focus problem is on record, so it clears.
  if [ "${CLAUDE_NOTIFY_FOCUS_CHECK:-1}" = "1" ] \
     && { [ -f "$PROBLEM_DIR/focus" ] || [ -z "$(find "$STATE_DIR/focus-checked" -mmin -10 2>/dev/null)" ]; }; then
    touch "$STATE_DIR/focus-checked"
    SINCE=$(date '+%Y-%m-%d %H:%M:%S')
    ( sleep 5; focus_check "$SINCE" ) &
  fi

  RESULT=$("$HELPER_BIN" post "$EVENT" "$TITLE" "$LABEL" "$MSG" 2>"$ERR_FILE")
  RC=$?
  if grep -q '^posted ' "$ERR_FILE" 2>/dev/null; then
    clear_problem auth
    clear_problem error
  fi
  log "helper said '$RESULT' rc=$RC state=$STATE_FILE stderr: $(tr '\n' '|' < "$ERR_FILE" 2>/dev/null)"

  case "$RESULT" in
    ALLOW)
      if [ "$EVENT" = "permission" ]; then
        "$SCRIPT_PATH" __dispatch__ "$STATE_FILE" allow
      else
        log "helper: ALLOW on a $EVENT card; ignoring"
      fi
      ;;
    SHOW)
      "$SCRIPT_PATH" __dispatch__ "$STATE_FILE" view
      ;;
    DISMISS|UNKNOWN:*)
      ;; # cleared, or an action we don't know: leave the tab alone
    *)
      if [ -z "$RESULT" ] && grep -q '^posted ' "$ERR_FILE" 2>/dev/null; then
        log "helper died after posting (killed? logout?); its card no longer answers"
      else
        log "helper showed nothing: '$RESULT' rc=$RC"
        case "$RESULT" in
          UNAUTHORIZED:*)
            record_problem auth "notify-hook: notifications are turned off for Claude Code (${RESULT#UNAUTHORIZED:}), so permission cards aren't shown. Fix: System Settings → Notifications → Claude Code → Allow notifications." ;;
          *)
            record_problem error "notify-hook: the notification helper failed (said '${RESULT:-nothing}', exit $RC); details in $LOG." ;;
        esac
      fi
      ;;
  esac
  rm -f "$ERR_FILE"
  exit 0
fi

# ---------------------------------------------------------------------- main

EVENT="$1"
INPUT=$(cat)

# Only these two notify; every turn end (stop) just reports setup problems,
# skipping the xirp/python label work.
case "$EVENT" in
  permission|elicitation) ;;
  stop) report_problems; exit 0 ;;
  *) exit 0 ;;
esac

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- tab identity

XIRP_SID=""
TMUX_SESSION=""
PANE=""

if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
  INFO=$(tmux display-message -p -t "$TMUX_PANE" '#S|#D' 2>/dev/null)
  if [ -n "$INFO" ]; then
    TMUX_SESSION="${INFO%%|*}"
    PANE="${INFO##*|}"
    case "$TMUX_SESSION" in
      xirp-*) XIRP_SID="${TMUX_SESSION#xirp-}" ;;
    esac
  fi
fi

# Legacy terminal detection, used only when we are not in a xirp tab.
case "${TERM_PROGRAM:-}" in
  WarpTerminal)   APP_NAME="Warp" ;;
  iTerm.app|iTerm2) APP_NAME="iTerm2" ;;
  vscode)         APP_NAME="Code" ;;
  *)              APP_NAME="Terminal" ;;
esac
CLAUDE_TTY="/dev/$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"

# xirp project names, cached for 10 minutes (id -> name).
PROJ_CACHE="${TMPDIR:-/tmp}/claude-notify-xirp-projects.json"
project_cache() {
  if [ ! -f "$PROJ_CACHE" ] || [ -n "$(find "$PROJ_CACHE" -mmin +10 2>/dev/null)" ]; then
    xirp project list --json 2>/dev/null > "$PROJ_CACHE.tmp" \
      && mv "$PROJ_CACHE.tmp" "$PROJ_CACHE" \
      || rm -f "$PROJ_CACHE.tmp"
  fi
  printf '%s' "$PROJ_CACHE"
}

# Human label for the tab: xirp session name + project name.
tab_label() {
  local label=""
  if [ -n "$XIRP_SID" ] && command -v xirp >/dev/null 2>&1; then
    label=$(xirp session get "$XIRP_SID" --json 2>/dev/null | "$PY" -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
name = (d.get("name") or "").strip()
if len(name) > 48:
    name = name[:47].rstrip() + "…"

# Prefer the xirp project name; a worktree directory basename is unreadable.
where = ""
try:
    with open(sys.argv[1]) as fh:
        for proj in json.load(fh):
            if proj.get("id") == d.get("projectId"):
                where = proj.get("name") or ""
                break
except Exception:
    pass
if not where:
    wt = (d.get("worktreePath") or "").rstrip("/")
    where = os.path.basename(wt) if wt else ""
    if len(where) > 24:
        where = where[:23].rstrip() + "…"

branch = (d.get("branch") or "").strip()
if branch in ("HEAD", "main", "master"):
    branch = ""
parts = [p for p in (name, where, branch) if p]
print(" · ".join(parts))
' "$(project_cache)" 2>/dev/null)
  fi
  if [ -z "$label" ]; then
    label=$(printf '%s' "$INPUT" | "$PY" -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cwd = d.get("cwd") or ""
print(os.path.basename(cwd.rstrip("/")) or "Claude Code")
' 2>/dev/null)
  fi
  [ -z "$label" ] && label="Claude Code"
  printf '%s' "$label"
}

# --------------------------------------------------------------------- notify

# write_state <file> <digit>
# Shell-sourceable state a later `__dispatch__` click reads back. Every value
# is quoted with %q so sourcing it back is safe regardless of its contents.
write_state() {
  local file="$1" digit="$2"
  {
    printf 'PANE=%q\n' "$PANE"
    printf 'XIRP_SID=%q\n' "$XIRP_SID"
    printf 'APP_NAME=%q\n' "$APP_NAME"
    printf 'CLAUDE_TTY=%q\n' "$CLAUDE_TTY"
    printf 'DIGIT=%q\n' "$digit"
  } > "$file"
}

# ---------------------------------------------------------------------- events

LABEL=$(tab_label)
log "label='$LABEL' xirp_sid='$XIRP_SID' pane='$PANE' term='${TERM_PROGRAM:-}'"

REQID="$$-$(date +%s)"
STATE_FILE="$STATE_DIR/$REQID.state"

case "$EVENT" in
  permission)
    PARSED=$(printf '%s' "$INPUT" | "$PY" -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
tool = data.get("tool_name", "unknown tool")
tool_input = data.get("tool_input", {}) or {}
if tool == "Bash":
    cmd = tool_input.get("command", "")
    description = tool_input.get("description", "")
    desc = f"{description}\n\n{cmd}" if description else cmd
elif tool in ("Edit", "Write", "Read"):
    desc = tool_input.get("file_path", "")
else:
    desc = json.dumps(tool_input)
if len(desc) > 600:
    desc = desc[:599] + "…"

always = ""
for s in data.get("permission_suggestions", []) or []:
    if s.get("type") == "addRules" and s.get("behavior") == "allow":
        rules = s.get("rules", [])
        if rules:
            r = rules[0]
            tn = r.get("toolName", "")
            rule = (r.get("ruleContent", "") or "").replace("//", "/")
            if tn and rule:
                always = f"Always allow {tn} {rule}"
            elif tn:
                always = f"Always allow {tn}"
if not always and data.get("permission_suggestions"):
    always = "Always"
if len(always) > 60:
    always = always[:59] + "…"
print(json.dumps({"msg": f"{tool}: {desc}", "always": always}))
' 2>/dev/null)

    MSG=$(printf '%s' "$PARSED" | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["msg"])' 2>/dev/null)
    ALWAYS_LABEL=$(printf '%s' "$PARSED" | "$PY" -c 'import sys,json; print(json.load(sys.stdin)["always"])' 2>/dev/null)
    [ -z "$MSG" ] && MSG="Needs permission"
    [ -n "$ALWAYS_LABEL" ] && MSG="$MSG (always: $ALWAYS_LABEL)"

    write_state "$STATE_FILE" "1"
    post_event permission "$LABEL" "$MSG" "$STATE_FILE"
    ;;

  elicitation)
    log "payload keys: $(printf '%s' "$INPUT" | "$PY" -c 'import sys,json
try: print(",".join(sorted(json.load(sys.stdin).keys())))
except Exception: print("unparsed")' 2>/dev/null)"
    MSG=$(printf '%s' "$INPUT" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
msg = d.get("message") or d.get("prompt") or d.get("question") or "Claude is waiting for your input."
if not isinstance(msg, str):
    msg = json.dumps(msg)
print(msg[:600])
' 2>/dev/null)
    [ -z "$MSG" ] && MSG="Claude is waiting for your input."

    write_state "$STATE_FILE" "1"
    post_event elicitation "$LABEL" "$MSG" "$STATE_FILE"
    ;;

  *)
    log "unhandled event"
    ;;
esac
