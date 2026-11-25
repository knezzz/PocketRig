# Push contract (app <-> native <-> watcher)

Draft from core.app, for core.native to accept or change. Nothing here is secret; keys stay on the host.

## 1. Tokens: native -> Dart

MethodChannel `dev.pocketrig/push` (Dart calls native; native calls Dart for events).

Dart -> native:
- `register()` -> asks for notification permission, registers for remote notifications / FCM. Returns `{"granted": bool}`.
- `startLiveActivity()` iOS only; not needed in slice 1. Slice 2 prefers the iOS 17.2+ push-to-start token, so the watcher can start the
  activity with the app closed; native then sends `activityStartToken {"token"}` at register time and `activityToken` per running activity.
- Cold start: native holds the `open` link until Dart's first `register()` call, then delivers it.

Native -> Dart (`invokeMethod` on the same channel):
- `token` `{"platform": "ios"|"android", "token": "<apns hex | fcm string>", "env": "sandbox"|"production"}`
  (`env` iOS only: native reads `aps-environment` from the embedded provisioning profile at runtime, because a `flutter build ios --release`
  signed with a development profile still talks to the sandbox gateway. Android omits it.)
- `activityToken` `{"token": "<hex>"}` iOS only, the push-to-start / per-activity token (slice 2, shape may grow).
- `action` `{"id": "<action id>", "url": "<answer url>", "body": "<json string>", "seat": "<session>"|null}` when a button
  is tapped and native could not post it itself (see 3).
- `open` `{"link": "pocketrig://seat/..."}` for a tap on the notification body (cold start or foreground).

Dart stores the token per host and writes it to the host's `~/.config/pocketrig/watcher.json` as
`"devices": [{"platform","token","env","name"}]` over the existing SSH save.

## 2. Push payload: watcher -> device

APNs alert: `aps.alert {title, body}`, `aps.category = "pr-permission" | "pr-question" | "pr-blocked" | "pr-result"`,
`aps.thread-id = <seq>`, `apns-collapse-id = <seq>` (result replaces the ask), `interruption-level: time-sensitive` for asks.
FCM: `data` only (no `notification` block, so the app/service builds it): `title, body, category, seq`; `android.collapse_key=<seq>`,
channel id `pocketrig-asks`.

Both carry the same custom keys:
- `link`: `pocketrig://seat/...` (tap target)
- `actions`: JSON string, array of `{"id","label","url","body"}` for the answer buttons only (Allow once / Deny / Snooze 1 h).
  `url` is the watcher `/answer`, `body` is the exact JSON string to POST (it already carries the HMAC `ticket`), with
  `Content-Type: application/json`. No bearer token ever rides in a push.
  "Open" and "Reply..." are not in `actions`: native adds them as foreground actions that open `link`.

Action ids (fixed): `allow`, `deny`, `snooze`, `open`, `reply`.
iOS categories (register at launch): `pr-permission` = allow, deny, open; `pr-question` = reply(foreground), open;
`pr-blocked` = open, snooze; `pr-result` = open.

## 3. Who posts the button tap

Native posts `body` to `url` itself (background URLSession on iOS, a short worker on Android), because the app may not be running.
If that fails or the app is foreground, native hands it to Dart via `action` and Dart posts it. Either way the watcher replaces the
notification with the result push (same `seq`).

## 4. Live Activity content state (slice 2, `PocketRigAttributes.ContentState`)

```json
{"needsCount": 3, "workingCount": 7,
 "rigs": [{"project": "pocketrig", "rig": "feature-notifications", "needs": 2, "working": 4}, {"project": null, "rig": "main", "needs": 0, "working": 2}],
 "rigCount": 2,
 "usage": [{"provider": "Claude", "h5": 42, "wk": 71, "h5Ahead": -8, "wkAhead": 12, "asOf": 1763416200}],
 "updatedAt": 1763416200}
```
`needsCount` / `workingCount` are the totals (a need-you agent is not also counted as working). `rigs` are the active rigs only (some agent needs you
or works), sorted needs desc, working desc, rig name, at most 3 (`project` null when the rig has none); `rigCount` is how many in all ("+N more").
`usage` is at most two providers: a label to show as is, `h5`/`wk` the freshest five-hour/weekly percent (0-100, null when the daemon has no such
window), `h5Ahead`/`wkAhead` how many percent points that window is over even pace, negative when under (the home rings' rule, worked out when the push is built; null when unknown). Native colours it on the green → amber → red gradient: ≤ -15 green, 0 amber, ≥ +15 red, linear between (test/fixtures/pace_colour.json), `asOf` epoch seconds of the freshest of the two. A provider whose freshest reading is over 15 minutes old is left out, because the card only redraws on a push. It comes from the daemon's `/api/provider/status` (read at most once a minute) and rides
along: a usage change alone never causes a push. There are no per-agent rows and no links: the card opens the app; need-you agents are reached through
the notification.
Static attributes: `{"host": "<hostName>", "tokenUrl": "<answer base>/activity-token?start=<id>", "ticket": "<hmac>"}` (`tokenUrl` and `ticket` are optional: absent when the watcher has no answer endpoint). Ended when both totals have been 0 for 10 minutes (agents flick idle and busy; until then the card shows the empty totals, and coming back cancels the end).

### How the watcher drives it (core.app)

Dart does not call `startLiveActivity`: an always-present empty activity would sit on the lock screen. Instead Dart writes native's
`activityStartToken` and `activityToken` into the phone's `devices` entry in watcher.json. The watcher starts the activity with
the push-to-start token (iOS 17.2+) when something needs you or is working, updates it through `activityToken` when the lists change,
and ends it when both are empty. Working = a rig agent with `agentActivity.state == running` and a reply (`modelObservation.observedAt`)
or hook event (`agentActivity.eventAt`) in the last 3 minutes. A device without an `activityStartToken` gets no Live Activity.

### Reporting a push-started activity's token (no app, no SSH)

Native observes `Activity<PocketRigAttributes>.activityUpdates` and each activity's `pushTokenUpdates` from launch. On every token it
POSTs `{"token": "<hex>", "ticket": "<attributes.ticket>"}` (JSON, no Authorization header) to `attributes.tokenUrl`.
The ticket is an HMAC of that one start's id, so it works for its own start only. Replies: 200 stored; 401 bad ticket;
404 the watcher restarted and forgot this start (nothing to retry); a network error is retried by native. The watcher then
updates and ends the activity through that token. Dart's `activityToken` into watcher.json stays for the foreground case.
The watcher logs one line per successful APNs/FCM send (`apns sent <category>`, `live activity start|update|end sent`), never tokens.
An answer other than 200 to a Live Activity push is logged too (`live activity update answered 410 ExpiredToken`: status and APNs reason).
Live Activity updates go at `apns-priority` 5 unless someone newly needs you (more in `needsCount` than the last push); a start, an end
and such an update go at 10. iOS budgets priority 10 pushes, and every update used to be one.

A swipe-away is not reported (the person chose not to build it): the watcher carries on with the activity's token and ends it after the usual
10 empty minutes, so swiping a card away hides it until the next start after that end.
