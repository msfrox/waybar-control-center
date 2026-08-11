# Handoff

**State: phases 0–8 shipped. Phase 10 (the bar) started here and moved to
[hyprbar](https://github.com/msfrox/hyprbar).** Repo: `msfrox/waybar-control-center`
(public). Everything is symlinked into `~/.config` by `install.sh`, so editing the repo
edits the live desktop.

This repo owns the **panels** — audio, Bluetooth, network, Claude usage, Control Center,
notifications — and the Waybar-side scripts. The **bar** that opens them is hyprbar, and
`~/.config/quickshell/BarApp` is symlinked from there, not from here. The split is
organisational: hyprbar calls into these panels over `qs ipc call` and shares the ML4W
`CustomTheme` singleton, so renaming an IPC target here breaks the bar.

## Resume

```bash
cd ~/Projects/waybar-control-center && ./install.sh
```

Reload after a change: **`pkill -x qs; qs -d`**. Quickshell claims to hot-reload QML, but
not reliably through the repo symlinks — if a QML edit appears to do nothing, restart
before believing the change is wrong. `~/.config/waybar/launch.sh` reloads Waybar.

## What exists

| Waybar module | Opens | Source |
|---|---|---|
| `pulseaudio` | audio panel (sliders, devices, Easy Effects) | `quickshell/AudioApp` |
| `bluetooth` | BlueZ panel | `quickshell/BluetoothApp` |
| `network` | NetworkManager panel + connection details + Tailscale | `quickshell/NetworkApp` |
| `image#claude-usage` | usage panel | `quickshell/ClaudeUsageApp` |
| `custom/controlcenter` | Control Center | `quickshell/ControlCenterApp` |
| `clock` | notification centre — clock, calendar, notification list | `quickshell/NotificationCenterApp` |

Backends in `waybar/scripts/`: `claude-usage.py`, `network-details.py`,
`system-stats.py`, `easyeffects-status.py`, `brightness.py`, `weather.py`,
`taskbar-window-click.sh`.

IPC targets: `qs ipc show`. This repo owns `audio`, `bluetooth`, `network`,
`claude-usage`, `control-center`, `notifications`, `notification-state`. The `bar`
target belongs to [hyprbar](https://github.com/msfrox/hyprbar). **These names are global
to the Quickshell instance** — renaming one here breaks the bar's buttons.

## Live gotchas

- **Never name an `IpcHandler` function `show`.** `qs ipc call <target> show` is swallowed
  by the CLI's own `ipc show` subcommand: it prints the handler listing, exits 0, and
  never reaches QML. Use `enable`/`disable`, which is what ML4W's `statusbar` handler
  does. Assume any other CLI verb is booby-trapped too.
- **Waybar's `network` signal reading goes stale.** It showed 33–40% while `nmcli` and
  our module both read ~48%. Ours is live off `Quickshell.Networking`; a difference here
  is Waybar being wrong, not us.
- **A commented-out module line needs a LEADING comma.** `"clock"` is last in
  `modules-right` and has no trailing comma, so uncommenting a `//"mpris",` under it
  produces `"clock" "mpris"` and Waybar refuses to start. Dormant entries are `//,"mpris"`.
- **`workspace-taskbar` needs `{windows}` in the workspace `format`** — undocumented, it
  is the flag the source tests. Without it no window icon is ever added.
- **Hyprland 0.56 parses dispatch payloads as Lua.** `dispatch focuswindow address:0x…`
  errors; use `hl.dsp.focus({ window = "address:0x…" })` and
  `hl.dsp.window.close({ window = "…" })`. `hl.dsp.window` is a *table*, not a function.
  Workspaces use `hl.dsp.focus({workspace = 'N'})`; branch on `Hyprland.usingLua`.
- **Never put a `gradient:` on a card Rectangle.** A QML gradient is a *fill*, so anything
  translucent inset inside it composites against the gradient, not the wallpaper. Test by
  setting the fill alpha to `0.0` — if the card looks identical, it was never see-through.
- **Frosted glass is two halves**: alpha in the QML fill *and* the
  `quickshell-frosted-glass` layer rule in `~/.config/hypr/shehan/theming.lua`. The whole
  Quickshell instance shares one layer namespace, `quickshell`.
- **Material Icons ligatures break inside a Controls `Button`** (it propagates its font
  onto `contentItem`), and **`highlighted` is FINAL on `Button`** — shadowing it fails the
  entire config to load with an error pointing at the property rather than the cause.
  Use a plain `Text` + `MouseArea`. Installed family is **Material Icons Round**.
- **`pkill -f <pattern>` matches the shell running it.** Use `pkill -x`. This bit again
  this session: `pgrep -af "qs -p"` matched its own zsh and the follow-up `kill` took out
  the tool's shell.
- **Quickshell owns `org.freedesktop.Notifications`.** swaync is D-Bus activatable, so
  `install.sh` masks `swaync.service`. See `docs/notifications.md`.
- **ML4W-owned files are patched in place, not shipped**: `modules.json`, the theme
  `config` and `style.css`, plus `CustomTheme/Theme.qml`, `PowerApp/`, `SidebarApp/` and
  `shell.qml`. `docs/quickshell-patches.md` records what to reapply after an ML4W update.
- **`~/.config/waybar/config` does not exist.** The live pair comes from
  `~/.config/ml4w/settings/waybar-theme.sh` → `~/.config/waybar/themes/ml4w-modern/`.
- **Commit authorship is enforced** by `.githooks/commit-msg` via `core.hooksPath`.
  A fresh clone needs it set again.

## Settings files this repo writes

| Path | Holds |
|---|---|
| `~/.config/waybar-control-center/claude-usage.json` | usage dial display options |
| `~/.config/waybar-control-center/notifications.json` | DND flag |
| `~/.config/waybar-control-center/control-center.json` | per-section collapse state, weather location |
| `~/.config/waybar-control-center/bar.json` | bar enabled / position / height — **written by hyprbar**, kept in this directory so hyprsys finds it |
| `~/.cache/waybar-control-center/notification-history.json` | notification history (capped at 50) |

Each panel watches its own file through a `FileView`, so nothing has to talk to the
running shell — that contract is what let the settings UI move to another repo.

## The settings app — moving to hyprsys, do not extend it here

`settings/` is being absorbed by [hyprsys](https://github.com/msfrox/hyprsys) phase 3. It
still works and is still installed; nothing is deleted until that lands. **No new settings
UI is built in this repo** — see PLAN.md, "The settings app, moved out". If a panel needs
a new option, add the setting *file* it reads and stop there.

## Next

Nothing is queued in this repo. The active work is in
[hyprbar](https://github.com/msfrox/hyprbar) (phase 3, the centre taskbar) and
[hyprsys](https://github.com/msfrox/hyprsys) (phase 3, absorbing `settings/`).

Two things here are waiting on those, and neither should be started early:

- **Delete `settings/`** and repoint the Control Center's Settings tile at `hyprsys`,
  once hyprsys phase 6 lands. It still works and is still installed until then.
- **Strip the PNG/signal-8 pipeline out of `waybar/scripts/claude-usage.py`**, once
  hyprbar phase 5 redraws the dial as a `Canvas`. Until then that script stays as it is,
  because Waybar is still one keypress away.

Everything else is in `BACKLOG.md`.
