# PocketRig watcher

A small Node script (Node 22+, no dependencies) that runs next to the OpenRig daemon. It posts to [ntfy](https://ntfy.sh) when a seat starts waiting on you, so your phone buzzes even when PocketRig is closed.

Every notification says where it comes from, as **role › rig › project › device** (e.g. `lead › conveyor › app › homelab`), and carries actions:

| Kind | Title | Actions |
|---|---|---|
| `permission` | *lead needs approval* — the tool and command below | **Allow once**, **Deny**, **Open** |
| `question` | *lead asked a question* — the question below | **Reply…** (opens the chat), **Open** |
| `blocked` | *lead is blocked on you* — an attention item from `/api/attention` | **Open**, **Snooze 1 h** |
| `rig` (off by default) | *conveyor stopped · snapshot s3* | — |

Answer buttons come first and Open last. Each ask is published with its own ntfy `sequence_id`; the result of a button (*✓ Allowed once · lead*, *Couldn't answer lead*, *Snoozed for 1 h*) is published under the same id, so ntfy replaces the notification instead of adding one. A *Couldn't answer* says what to do (e.g. *Already answered, nothing to do.*). When the phone can't reach the watcher at all (Tailscale off), the request never arrives, so the watcher can't say so: the ntfy app reports the failed action and the ask stays up.

Tapping the body opens the seat in the app: the chat for Claude seats, the terminal otherwise.

## How it works

- It listens to the daemon's global event stream (`GET /api/events?replay=0`). On any seat, node, session or queue event it re-reads `/api/ps` and each running rig's `/nodes`.
  - It uses the global stream because only that stream carries `seat.activity_changed`.
- It also polls every 8 s as a safety net. The daemon sends no SSE heartbeats, so a silently dropped stream would otherwise go unnoticed.
- A seat notifies once each time it goes from not waiting to waiting. It uses the same needs-input rule as the app.
- New `action` items from `/api/attention` also notify.
- Seats already waiting when the watcher starts are not announced (set `POCKETRIG_NOTIFY_EXISTING=1` to change that).
- The notification's click link is `pocketrig://seat/<session>?host=<host>` (plus `&view=chat` for questions).

## Answering from the notification

**Allow once** and **Deny** are ntfy `http` actions: the phone POSTs straight to the watcher's `/answer` endpoint on port **7434** with a bearer token. The watcher then:

1. checks the token (constant-time) and that the seat is still waiting — otherwise it answers 409 and posts *Couldn't answer*;
2. sends the key to the seat through the daemon's terminal socket (`1` to allow, `Escape` to deny), falling back to `tmux send-keys`;
3. replaces the notification with a short result, e.g. *✓ Allowed once · lead* (same ntfy sequence id).

There is deliberately no *Always allow* button: that changes the seat's permission mode, which stays in the app.

The phone must reach the host, so **Tailscale has to be on** for the buttons to work; Open and Reply… just open the app. The token is random, kept in `~/.config/pocketrig/answer-token` (mode 600), and only travels inside notifications on your topic — another reason to keep the topic private.

## Agents outside a rig

`install.sh` also adds a Claude Code hook (`claude-hook.sh`) to `~/.claude/settings.json`, for `SessionStart`, `Notification`, `PostToolUse`, `UserPromptSubmit`, `Stop` and `SessionEnd`. Each event is POSTed to `http://127.0.0.1:7434/hook` with the token, the tmux pane (`$TMUX_PANE`) and its session name. The hook never blocks Claude: it gives up after 2 s and always exits 0. Skip it with `POCKETRIG_NO_CLAUDE_HOOKS=1 ./install.sh …`; add it later with `node pocketrig-watcher.mjs install-hooks "$PWD/host/watcher/claude-hook.sh"`.

- Sessions that are rig seats are ignored; the daemon already reports them.
- When a session started by hand asks for permission, the watcher notifies as `scratch › no rig › app › homelab` (the tmux session name, or `claude` outside tmux). The command comes from the end of its transcript.
- **In tmux:** Allow once / Deny / Open. The answer goes to the pane with `tmux send-keys`.
- **Not in tmux:** only **Open chat**, which is read-only. There's no way to press a key in a plain terminal tab, so answer it at the Mac, or tap **Restart in tmux** in the app: it stops the process and runs `claude --resume <id>` in a new tmux session, so the same conversation can take messages and answers from the phone. In Terminal and iTerm, the tab it ran in then attaches to that session. The first time, macOS asks at the Mac to allow `sshd-keygen-wrapper` to control the terminal; until that's allowed, or in any other terminal, the app shows the `tmux attach` command instead.
- **Kill session** in the app ends the agent over SSH and posts its `SessionEnd` to `/hook`, because a killed process may not fire that hook itself.
- The watcher keeps what it saw in `~/.config/pocketrig/loose.json`. The app reads it over SSH and merges it with the daemon's tmux scan (`/api/discovery`).
- Codex has no permission hook, so Codex sessions outside a rig are listed by the scan but never notify.

## Settings from the app

When you save a host in the app, it writes `~/.config/pocketrig/watcher.json` over SSH:

```json
{"hostName": "homelab", "address": "mini.tailXXXX.ts.net", "kinds": ["permission", "question", "blocked"]}
```

The watcher re-reads it on every check, so the device name, the address the buttons call and **Notify me about** take effect without a restart. Env vars still win where both are set.

## Install (macOS, launchd)

1. In the app, open **Hosts → your host → Notifications**. Tap the dice to generate a topic, then save the host.
2. Tap **Set up on this host** there. Over SSH, the app uploads the watcher, the hook and this installer to `~/.config/pocketrig/` and runs it, then checks that the watcher answers and the hooks are in place. It backs up `~/.claude/settings.json` to `settings.json.pocketrig-backup`, replaces any PocketRig hook at an older path, and leaves your other hooks alone. If launchd refuses an SSH session, it tells you the command to run at the Mac. Or, on the host, from this checkout:

   ```sh
   ./host/watcher/install.sh pocketrig-xxxxxxxxxxxxxxxx            # ntfy.sh
   ./host/watcher/install.sh pocketrig-xxxx https://ntfy.example.com # self-hosted
   ```

   This writes `~/Library/LaunchAgents/dev.pocketrig.watcher.plist` and starts the watcher. launchd keeps it running alongside the daemon. Logs go to `~/Library/Logs/pocketrig-watcher.log`.
3. On the phone, install the ntfy app and tap **Subscribe in ntfy** in the host settings.

Remove the watcher with `./host/watcher/install.sh --uninstall`.

The third argument to `install.sh` is the host name the app matches links against. It defaults to `scutil --get LocalHostName`, which matches a host saved as `mini.tailXXXX.ts.net`. If the app knows the host by a different name, pass that name.

## Configuration

| Variable | Default | |
|---|---|---|
| `POCKETRIG_NTFY_TOPIC` | (required) | Letters, digits, `-` and `_` |
| `POCKETRIG_NTFY_SERVER` | `https://ntfy.sh` | |
| `POCKETRIG_NTFY_TOKEN` | none | For a protected topic. Add it to the plist's `EnvironmentVariables` |
| `POCKETRIG_HOST` | hostname | Device name in notifications and `host=` in links |
| `POCKETRIG_ADDRESS` | hostname | How the phone reaches this host (the buttons call `http://<address>:7434`) |
| `POCKETRIG_ANSWER_PORT` | `7434` | `0` turns the Allow/Deny buttons off |
| `POCKETRIG_ANSWER_BIND` | `0.0.0.0` | Every request needs the token anyway |
| `POCKETRIG_ANSWER_URL` | `http://<address>:<port>` | Override, e.g. behind a proxy |
| `POCKETRIG_ANSWER_TOKEN` | random, persisted | |
| `POCKETRIG_KINDS` | `permission,question,blocked` | Also `rig` |
| `POCKETRIG_NOTIFY_EXISTING` | off | `1` also announces seats already waiting at start |
| `OPENRIG_URL` | `http://127.0.0.1:7433` | |
| `POCKETRIG_POLL_MS` | `8000` | Safety-net poll |

**Privacy:** anyone who knows a topic on ntfy.sh can read it. The generated topic is 16 random characters. Notifications include rig and seat names and the daemon's reason text (e.g. `Bash: npm test`), but never terminal contents. For more privacy, self-host ntfy or use an access token.

## Test

```sh
node --test host/watcher/watcher.test.mjs
```

The end-to-end tests run a fake daemon and a fake ntfy server. They check that a seat which starts waiting reaches ntfy in under 10 s with the role › rig › project › device path, and that tapping **Allow once** sends the key to the seat and posts the result.
