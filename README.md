# OC Profile Switcher

A small, privacy-first, always-on-top Windows overlay for OpenCode multi-account management.

![PowerShell](https://img.shields.io/badge/PowerShell-WPF-blue) ![Windows](https://img.shields.io/badge/Windows-10%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

---

## Privacy first

**OC Profile Switcher never displays, copies, stores, or logs API keys, OAuth tokens, or any other credential.**

- The widget renders only a display-safe status snapshot.
- The bridge builds its response with an **explicit allow-list** of non-sensitive fields — it never passes a raw account object through, so there is no denylist that could be forgotten as the schema grows.
- Credentials are read on disk only to determine *health*, and only the resulting boolean state ever reaches the UI.
- The bridge reloads account state from disk before every read, so no credential is ever held in a long-lived widget-side cache.
- Everything runs locally. The widget makes no outbound network requests.

See [Privacy design](#privacy-design) for the specifics.

## Built for free, unlimited AI usage

If you run OpenCode against free or unlimited-quota accounts, you need a control surface that makes account rotation legible at a glance instead of guessing which provider is cooling down, how much rate-limit churn you are eating, and how close the current session is to your context budget.

OC Profile Switcher is that surface. It is a **local control panel only**:

- It does **not** add, extend, or unlock any quota — it consumes none of its own.
- It does **not** transmit credentials or account data anywhere. There is no telemetry and no server.
- It does not proxy or modify requests. It only reads status and asks your existing account manager to switch.

It sits on top of an existing OpenCode free/unlimited usage setup and makes it observable and manageable from the desktop.

## What it does

- Shows the current global account and provider.
- Shows healthy/cooling account counts.
- Tracks rate-limit events, automatic rotations, and manual switches.
- Shows current context tokens against the local budget when session data is available.
- Switches accounts globally or for the detected active session.
- Hides to the Windows notification area instead of closing.
- Minimizes to a tiny always-on-top tracker with account, health, and context progress.
- Can appear automatically when OpenCode Desktop or the OpenCode terminal starts.

## Requirements

- Windows 10 or later
- PowerShell 5.1+ (built in)
- Node.js with the built-in `node:sqlite` module (Node 22.5+) — used by the bridge, which is run in-process by the widget
- Your existing OpenCode multi-account manager (the widget delegates switching to it)

No third-party packages. The bridge uses only Node.js built-ins.

## Start manually

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\.config\opencode\oc-profile-switcher\OpenCodeAccountWidget.ps1"
```

Adjust the path to wherever you cloned this repository.

## Install at Windows startup

Run `Install.ps1` from this directory. It copies the widget to `%LOCALAPPDATA%\OpenCodeAccountWidget`, creates a Startup shortcut, and starts the watcher once. The watcher stays in the tray and shows the widget whenever OpenCode is running.

Run `Uninstall.ps1` to remove the shortcut, the installed copy, and any running instance.

## Controls

- Click the compact card or the `▾` button to expand.
- Click the minus button to minimize to the tiny tracker; click the tiny tracker or plus button to restore it.
- Use `USE` to switch the selected account.
- Use the target selector to choose `Global default` or `This session`.
- Drag the title to move the widget.
- Use the tray icon to show it again or exit it.

## Architecture

| File | Role |
| --- | --- |
| `OpenCodeAccountWidget.ps1` | The WPF widget. Rendering, interaction, and the long-lived bridge host. |
| `account-bridge.mjs` | Node bridge. Wraps the account manager and returns **display-safe status only**. |
| `widget-config.json` | Local preferences (context budget, poll interval, auto-show behavior). |
| `Install.ps1` / `Uninstall.ps1` | Startup shortcut management. |

### Live data and shared state

- The widget keeps one long-lived bridge process alive. The bridge owns one account-manager instance and reloads state before every snapshot and switch, so account state is never served from a widget-side cache.
- The bridge, OpenCode server plugin, and TUI use the same atomic account/state files. Separate processes cannot share a JavaScript heap, so reload-before-read is the synchronization boundary.
- Context usage is recalculated on every poll from the active session's message records. It sums token counts for active message blocks rather than trusting JSON property enumeration order or the last message.
- Provider credits are read fresh from the quota file on every poll. That optional file can be keyed by account ID or provider:

  ```json
  {
    "<account-id>": {
      "used": 1200,
      "limit": 10000,
      "updatedAt": "2026-01-01T00:00:00.000Z"
    }
  }
  ```

  If no live quota source exists, the widget displays `n/a` rather than reusing a stale value or fabricating credits.

### Privacy design

Three properties are load-bearing:

1. **Allow-list serialization.** `cleanAccount()` and `cleanSwitchedAccount()` in `account-bridge.mjs` construct a *new* object from a fixed set of non-sensitive fields. Sensitive properties cannot leak by omission, because omission is the only mechanism — nothing is copied.
2. **Reload-before-read.** `manager.reload()` runs before every snapshot, so credentials are never cached across the widget's lifetime.
3. **Aggregate-only health.** Credential-derived information is reduced to a boolean/status before crossing the bridge boundary. Raw material never crosses it.

The per-account allow-list is:

```
id · name · provider · priority · status · cooldownRemainingMs · selectable · isGlobalCurrent · isSessionCurrent
```

## Configuration

`widget-config.json`:

```json
{
  "localBudgetTokens": 1000000,
  "pollMs": 2000,
  "autoStartWithOpenCode": true,
  "hideWhenOpenCodeClosed": true
}
```

| Key | Meaning |
| --- | --- |
| `localBudgetTokens` | Context budget to measure usage against. Set to your model's context window. |
| `pollMs` | Refresh interval in milliseconds. |
| `autoStartWithOpenCode` | Show the widget automatically when OpenCode starts. |
| `hideWhenOpenCodeClosed` | Hide the widget when OpenCode is not running. |

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This is an independent local utility. It is not affiliated with or endorsed by the OpenCode project. You are responsible for complying with the terms of service of any account or provider you connect it to.