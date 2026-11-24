# notify-persist

Claude Code's desktop-notification hook (`notify.sh`). For a permission request
it posts **one** macOS Notification Center card with real **Allow** and
**Show** buttons. For an elicitation (Claude asking a question) the card has
**Show** only. The card sits in Notification Center until you act on it. It
never times out the way the old `display alert ... giving up after 45` modal
did.

- **Allow** types `1` into the exact tmux pane that asked, and only when that
  pane is still showing a numbered choice prompt.
- **Show** focuses that tab: the `xirp://` deep link for a xirp tab, otherwise
  the old Terminal/iTerm2/Warp/VS Code activation.
- **Clearing the card**, or never touching it, does nothing.

## Setup steps

**Run `./setup.sh`.** It checks the six steps below in order. It does what it
can itself: builds and signs the helper, asks macOS for permission, opens the
right System Settings page, and tests a card against your current Focus. For
everything else it prints the exact click, as a ✗ with a → fix. Re-run it any
time something seems off. `./setup.sh --install-hook` also does step 6.

1. **Code-signing identity.** You need a free Personal Team "Apple Development"
   certificate: Xcode → Settings → Accounts → `+` (any Apple ID) → select the
   Personal Team → Manage Certificates… → `+` → Apple Development.
   `security find-identity -v -p codesigning` should list
   `"Apple Development: <name> (<id>)"`.

2. **Helper built and signed.** `helper/build.sh` signs with the first
   `Apple Development:` identity it finds; set `CODESIGN_IDENTITY=<name or
   SHA-1>` to pick a different one. With no identity it **fails** rather than
   ad-hoc signing (see "Signing" below). `setup.sh` rebuilds when the helper is
   missing, ad-hoc signed, fails to verify, or is older than
   `helper/src/main.swift`. Rebuilding is safe while cards are up: the new
   binary is renamed over the old one, never rewritten in place.

3. **Notifications allowed for "Claude Code".** That's the helper's name in
   System Settings, with the Claude icon. On first run, macOS shows "Claude
   Code would like to send you notifications": click **Allow**, and leave
   `setup.sh` (or `AllowShowNotifier authorize`) running until you've
   answered. macOS asks only once per bundle id. A prompt that goes away
   unanswered is recorded as **denied** (that happened during setup on this
   Mac), and after that the only way is System Settings → Notifications →
   Claude Code → **Allow notifications**. `setup.sh` opens that page and waits
   for you.

4. **Alert style (optional).** **Persistent** keeps a card in the corner until
   you act. Temporary, the default, slides it into Notification Center after a
   few seconds, where it still waits. Set it in System Settings → Notifications
   → Claude Code.

5. **Focus modes let the cards through.** Do this for every Focus you use
   (e.g. **Work**): System Settings → Focus → *Work* → Allowed Notifications →
   Apps → Add → **Claude Code**. Otherwise the Focus silently files every card
   into Notification Center with no banner. `setup.sh` checks this by posting a
   self-removing test card ("notify-hook setup check") and reading
   `donotdisturbd`'s verdict on it from the unified log: `suppression=0` means
   shown, anything else means hidden. If no Focus is on at that moment, there
   is no verdict, and it reminds you to add Claude Code to the ones you use.

6. **Claude Code runs this checkout.** `~/.claude/settings.json` runs
   `~/.claude/hooks/notify.sh <permission|elicitation|stop>` on PermissionRequest,
   Elicitation and Stop. That file should be a wrapper that `exec`s this
   checkout's `notify.sh`. `./setup.sh --install-hook` writes it and keeps the
   old file as `notify.sh.pre-helper`; by hand:

   ```sh
   mv ~/.claude/hooks/notify.sh ~/.claude/hooks/notify.sh.pre-helper
   printf '#!/bin/bash\nexec %s/notify.sh "$@"\n' "$PWD" > ~/.claude/hooks/notify.sh
   chmod +x ~/.claude/hooks/notify.sh
   ```

   The wrapper runs `notify.sh` from the checkout, so it finds
   `helper/AllowShowNotifier.app` beside it (the notification permission
   belongs to that bundle) and logs to `notify.log` here. Keep the checkout on
   `main`: whatever branch is checked out is what every session runs. To undo,
   `mv ~/.claude/hooks/notify.sh.pre-helper ~/.claude/hooks/notify.sh`.

### When something breaks later

The hook notices problems itself and **tells you in the Claude Code session**
at the end of a turn:

```
⏺ …
  ⎿  Stop says: notify-hook: notifications are turned off for Claude Code (denied), so permission
     cards aren't shown. Fix: System Settings → Notifications → Claude Code → Allow notifications.
     Check every setup step: …/notify-hook/setup.sh
```

| It notices | When | Setup step |
|---|---|---|
| helper missing, ad-hoc signed or unsigned, signature broken | every event | 2 |
| notifications turned off for Claude Code (`UNAUTHORIZED:<status>`) | every event | 3 |
| the helper failing to post (`ERROR`, crashed) | every event | 2 / `notify.log` |
| a Focus hiding the cards (`donotdisturbd` verdict ≠ 0) | 5s after a card is posted, at most every 10 min | 5 |

Each problem is recorded under `$TMPDIR/claude-notify-state/problems/`. The
next Stop hook in any session shows it, at most once an hour per problem. The
next event that works clears it. Claude Code shows a Stop hook's
`systemMessage` but not one from a PermissionRequest hook (checked on
2.1.331), which is why the message arrives at the end of the turn rather than
with the prompt. Set `CLAUDE_NOTIFY_FOCUS_CHECK=0` to skip the Focus check.

There is **no fallback**. When the helper can't post, no card appears.
`notify.log` has the details, one line per event:

- `helper unusable: <why> -- nothing posted`
- `helper showed nothing: 'UNAUTHORIZED:denied'`
- `problem[<kind>] recorded/cleared`
- `helper said 'ALLOW'`, followed by `send-keys -t %NN '1'`: the click worked.

## How it works

```
Claude Code hook ──► notify.sh permission
                       │ tab identity (TMUX_PANE → pane, xirp-<uuid> → session id)
                       │ writes a state file (pane, xirp id, legacy app/tty, digit)
                       └─► setsid notify.sh __await_helper__ <state> …   (detached; hook returns ~200ms)
                              └─► AllowShowNotifier post permission <title> <label> <message>
                                     … blocks until the card is acted on …
                                     prints ALLOW | SHOW | DISMISS   (or UNAUTHORIZED:<s> / ERROR)
                              ALLOW ─► notify.sh __dispatch__ <state> allow ─► do_answer (tmux send-keys)
                              SHOW  ─► notify.sh __dispatch__ <state> view  ─► do_focus  (xirp deep link)
```

- **`helper/AllowShowNotifier.app`** is a small Swift app (`helper/src/main.swift`)
  built on `UNUserNotificationCenter`. It registers two categories,
  `PERMISSION_CATEGORY` (Allow, Show) and `ELICITATION_CATEGORY` (Show). It
  knows nothing about tmux or xirp. Its only job is answering "what did the
  user click".
- **`__dispatch__`** (`pane_awaiting_choice`, `do_answer`, `do_focus`) is the
  click logic that was already built and tested. Apart from comments it is
  byte-identical to `0ef7fe1`.
- **Routing between concurrent cards.** Every waiting `post` process shares one
  bundle id, and macOS hands each click to whichever of those processes it
  picks, not necessarily the one that posted that card. In testing, with four
  cards up, all four clicks reached the wrong process. So a process that
  receives a click for another request id relays it over a distributed
  notification addressed to that id, and each process listens only for its
  own. Without the relay, clicking Allow on tab A's card could type `1` into
  tab B.
- The Show action deliberately lacks the `.foreground` option. With it, macOS
  also launched a fresh, argument-less copy of the app on every Show click.

### Signing

`helper/build.sh` signs with a real Apple Development identity and never falls
back to ad-hoc. `notify.sh` refuses to use an ad-hoc build: no `Authority=`
line in `codesign -dvv`, or `codesign --verify --strict` fails.

amfid rejects an ad-hoc build:

```
amfid: …/AllowShowNotifier not valid: Error Domain=AppleMobileFileIntegrityError Code=-423
"The file is adhoc signed or signed by an unknown certificate chain"
```

A signed build logs no such line. On the managed work Mac, the `-423` build
never got a permission prompt (see `TODO.md`). **On this Mac (macOS 26.2), the
ad-hoc build still got the permission prompt** despite the `-423`. So signing
is the safe requirement, but here it was not what unblocked the prompt.

## Testing performed

The `notify.sh` tests targeted isolated tmux panes running a fake numbered
prompt (`nh-test-*`), plus two throwaway xirp tabs (`notify-test XH` / `XT`,
created with `xirp session new-terminal`, running only the fake prompt). They
never touched a real Claude session. Every run checked the target pane's
session name before sending.

**Actually fired:**

- **Signing.** `-423` appeared once in the ad-hoc run's log and zero times in
  either signed-run log window. Signed chain: Apple Development → WWDR →
  Apple Root CA.
- **Helper only.** Four concurrent cards (Allow, Show, clear, elicitation),
  clicked by hand. Each printed exactly one line, and the words were right
  (`ALLOW`, `SHOW`, `DISMISS`, `SHOW`). Every one landed in the wrong process,
  which is the routing bug above. Leo confirmed the permission cards showed
  Allow + Show and the elicitation card showed Show only.
- **Relay, synthetic.** A relay for another request id was ignored. One for
  the card's own id made it print `SHOW` once and exit 0.
- **notify.sh, isolated panes, real clicks, four concurrent cards.**
  macOS misrouted 3 of 4 responses, and all 3 were relayed (`relayed … for
  <id>` in the log). Each waiter dispatched its own card: Allow sent `1` to
  the right pane only, Show dispatched `view`, clearing did nothing.
- **notify.sh, xirp tabs, real clicks.** Show ran
  `focus xirp 41e1522c…` and landed on the `notify-test XH` tab (Leo
  confirmed). That response was relayed from the other card's process. Allow
  ran `send-keys -t %44 '1'`, which the tab logged at 10:49:37.
- **Every branch with a stub helper** (signed shell script) and a stub
  terminal-notifier on PATH:
  - missing or ad-hoc helper: `helper unusable`, nothing posted;
  - `UNAUTHORIZED`, `ERROR`, or a crash before posting: `helper showed
    nothing`;
  - a crash after posting: logged separately;
  - `ALLOW` on an elicitation card: ignored;
  - `stop`: exits in about 20ms.

  terminal-notifier was never invoked.
- **Live path.** After the cutover, a card posted through
  `~/.claude/hooks/notify.sh` → wrapper → this checkout, and Work Focus let it
  through (`suppression=0`).
- **Work Focus.** Before Claude Code was added to Work's allowed apps,
  `donotdisturbd` suppressed every card. Afterwards cards broke through.

- **Problem reporting, with `TMPDIR` pointed at a scratch dir so nothing
  reached real sessions.** Covered: an unusable helper, `UNAUTHORIZED`,
  `ERROR`, a Stop rate-limited on its second run, and a working event clearing
  all three. For the Focus check, a live verdict from a terminal-notifier card
  that Work Focus hid (`suppression=2`) recorded the problem, and a probe card
  that got through (`suppression=0`) cleared it.
- **The message reaching the session.** In an isolated `claude` session
  (`--setting-sources project`, a scratch folder, Haiku), the real
  `notify.sh stop` printed `Stop says: notify-hook can't post permission
  cards: …` under the turn. The same check showed that a PermissionRequest
  hook's `systemMessage`, and its stderr on `exit 1`, are never displayed, and
  that `exit 1` still leaves the normal permission prompt.
- **`setup.sh`** passes all six steps on this Mac. The probe card was presented
  and removed itself after 3s.

**Reasoned about, not fired:**

- A waiter dies (logout or reboot) while its card is up. A later click then
  either launches an argument-less copy of the app, which prints usage and
  exits, or is relayed to an id nobody owns. Nothing happens either way.
- Each open card costs one sleeping helper process plus its waiter until it
  is acted on or cleared.
- `status` is a diagnostic only. A click delivered to a `status` process in the
  few milliseconds it is connected would be lost, which is why `notify.sh`
  never calls it.

## Not yet done / open

- **Certificate lifetime.** The Personal Team certificate is valid Feb 2
  2026 → Feb 2 2027 (`security find-certificate -c "Apple Development: Leonid
  Belyi" -p | openssl x509 -noout -dates`). Whether a locally-signed,
  non-sandboxed app built with it keeps working that long has not been
  verified; that needs elapsed time. Observed so far: notification
  authorization survived a rebuild that changed the cdhash (same bundle id
  and team).
