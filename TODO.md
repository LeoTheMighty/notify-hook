# TODO: real "Allow"/"Show" buttons on one notification card

**Status: done (2026-11-24, on Leo's personal Mac).** `notify.sh` now posts one
card with real Allow/Show buttons via `helper/AllowShowNotifier.app`, and it is
the live hook. README.md has the setup steps and the testing record. The
terminal-notifier two-card workaround this file used to describe was removed
at Leo's request.

## What the original blocker turned out to be

Written on the MDM-managed work Mac: `requestAuthorization` came back denied
with no prompt, and amfid logged `AppleMobileFileIntegrityError Code=-423 "The
file is adhoc signed or signed by an unknown certificate chain"`. The
conclusion then was that the ad-hoc signature blocked the prompt.

On the personal Mac (macOS 26.2 25C56, Xcode 26.3, Personal Team identity
`Apple Development: Leonid Belyi (DN74J597YH)`, team `H66YP2QFW2`):

- The ad-hoc build **still logged -423 and still got the permission prompt.**
  usernoted presented `com.apple.notificationcenter.askpermissions` as an
  alert, so here -423 did not gate the prompt.
- That test ran under a 30-second kill timer. The prompt was removed when the
  process died, and macOS recorded the app as **denied**. After that, every
  request, signed or not, was refused at once (`UNErrorDomain Code=1
  "Notifications are not allowed for this application"`) with no prompt. The
  fix was System Settings → Notifications → Claude Code → Allow. That is
  plausibly what happened on the work Mac too: an unanswered first prompt,
  then silent denials. It can't be checked from here.
- The signed build logs no -423. `helper/build.sh` now requires a real
  identity and never falls back to ad-hoc.

## Found and fixed along the way

- **Clicks were routed to the wrong card's process.** macOS delivers a
  response to any process holding the bundle id's connection. The helper now
  relays non-matching responses to their owner over a distributed
  notification. Details are in README.md.
- **Work Focus suppressed every card.** The fix is adding Claude Code to the
  Focus's allowed apps (README setup step 5).
- **The Show action had `.foreground`**, so macOS launched an extra,
  argument-less copy of the app on every click. Removed.

## Still open

- **Does a free Personal Team certificate keep working for a locally-signed,
  non-sandboxed `.app`?** The certificate itself is valid Feb 2 2026 → Feb 2
  2027. Nothing here uses an embedded provisioning profile, so the iOS 7-day
  reprovisioning rule shouldn't apply, but that is unverified; it needs
  elapsed time. If it breaks, `notify.log` will start saying `helper
  unusable` or `helper showed nothing`, and `helper/build.sh` re-signs.
  Observed so far: authorization survived rebuilds (new cdhash, same bundle id
  and team).
