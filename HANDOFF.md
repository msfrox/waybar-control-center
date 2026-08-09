# Handoff

**State: phases 0–8 shipped and running live on RUBY2.** Repo:
`msfrox/waybar-control-center` (public). Everything is symlinked into `~/.config` by
`install.sh`, so editing the repo edits the live desktop.

## Resume

```bash
cd ~/Projects/waybar-control-center && ./install.sh
```

Reload after a change: `~/.config/waybar/launch.sh` for bar changes. Quickshell hot-reloads
QML on save, but **not reliably through the repo symlinks** — if a QML edit appears to do
nothing, `pkill -x qs` and relaunch `qs -d` before believing the change is wrong.

## What exists

| Waybar module | Opens | Source |
|---|---|---|
| `pulseaudio` | audio panel (sliders, devices, Easy Effects) | `quickshell/AudioApp` |
| `bluetooth` | BlueZ panel | `quickshell/BluetoothApp` |
| `network` | NetworkManager panel + connection details + Tailscale | `quickshell/NetworkApp` |
| `image#claude-usage` | usage panel | `quickshell/ClaudeUsageApp` |
| `custom/controlcenter` | Control Center | `quickshell/ControlCenterApp` |
| `clock` | notification centre — clock, calendar, notification list | `quickshell/NotificationCenterApp` |
| `custom/appmenu` | app launcher, centre of the bar | ML4W's |
| `hyprland/workspaces` | grouped taskbar — window icons per workspace | Waybar built-in + `taskbar-window-click.sh` |

Backends in `waybar/scripts/`: `claude-usage.py`, `network-details.py`, `system-stats.py`,
`easyeffects-status.py`, `brightness.py`, `weather.py`, `taskbar-window-click.sh`.

IPC targets: `qs ipc show`. The ones this repo owns are `audio`, `bluetooth`, `network`,
`claude-usage`, `control-center`, `notifications`, `notification-state`.

## Live gotchas

- **A commented-out module line needs a LEADING comma.** `"clock"` is the last entry in
  `modules-right` and carries no trailing comma, so uncommenting a `//"mpris",` under it
  produced `"clock" "mpris"` — Waybar then refuses to start with
  `Error parsing JSON: Missing ',' or ']' in array declaration` and the bar simply never
  appears. The dormant entries are therefore written `//,"mpris"`. A trailing comma before
  the closing `]` *is* tolerated, so leading commas are safe in any combination.
- **`workspace-taskbar` needs `{windows}` in the workspace `format`.** Undocumented in the
  man page; it is the flag the source tests. Without it the module loads and styles
  correctly and no window icon is ever added — it reads as a CSS bug and is not.
  Workspace *labels* are also unclickable by design here; see
  `waybar/modules/workspace-taskbar.json` for why, and why `ext/workspaces` stays on the left.
- **Both workspace modules render as `#workspaces`.** `ext/workspaces` (left) and
  `hyprland/workspaces` (centre) share the id, so the left module's pill styling lands on
  every window icon in the centre. All of `waybar/style/workspace-taskbar.css` is scoped to
  `.modules-center` for that reason.
- **This Waybar build has no `cava`.** It logs `Unknown module` and leaves a gap. Needs a
  rebuild with `-Dcava=enabled`.
- **Hyprland 0.56 parses dispatch payloads as Lua.** `dispatch focuswindow address:0x…`
  errors; the working forms are `hl.dsp.focus({ window = "address:0x…" })` and
  `hl.dsp.window.close({ window = "address:0x…" })`. Note `focuswindow` and `killactive`
  do not exist as Lua fields at all — `hl.dsp.window` is a *table*, not a function.
  Enumerate with `hyprctl eval` writing to a file; `hyprctl dispatch` wraps its argument in
  `return hl.dispatch(...)` and cannot introspect.
- **Weather glyphs must be Material Icons *Round*, not Material Symbols.** `rainy`,
  `clear_day`, `foggy` and friends are Symbols names, that font is not installed, and a
  missing ligature renders as *nothing* — the chip loses its icon while the temperature
  still shows, so it looks like a layout bug. `weather.py`'s `ICONS` map carries a
  one-liner for verifying a name against the installed font before adding it.
- **`~/.config/waybar/config` does not exist.** The live pair comes from
  `~/.config/ml4w/settings/waybar-theme.sh` → `~/.config/waybar/themes/ml4w-modern/`.
  Confirm with `ps aux | grep '[w]aybar -c'`.
- **ML4W-owned files are patched in place, not shipped**: `modules.json`, the theme
  `config` and `style.css`, plus `CustomTheme/Theme.qml`, `PowerApp/`, `SidebarApp/` and
  `shell.qml` under `~/.config/quickshell/`. An ML4W update can clobber any of them —
  `docs/quickshell-patches.md` records what to reapply. (`CalendarApp/` is no longer used.)
- **Quickshell owns `org.freedesktop.Notifications`.** swaync is D-Bus activatable, so
  killing it is not enough — `install.sh` masks `swaync.service`, and only that survives a
  swaync package update or an ML4W dotfiles update. The `pkill` in
  `~/.config/hypr/shehan/notifications.lua` is the second half, covering ML4W's direct exec.
  If notifications stop arriving, check the owner and the mask first — `docs/notifications.md`
  has both one-liners and the full chain.
- **Never put a `gradient:` on a card Rectangle.** A QML gradient is a *fill*: it paints the
  whole card, and a translucent rectangle inset inside it then composites against the
  gradient instead of the wallpaper. Every panel here was opaque for months because of it.
  Test by setting the fill alpha to `0.0` — if the card looks identical, it was never
  see-through. Cards are now one Rectangle: translucent fill + hairline `border`.
- **Frosted glass is still two halves.** Alpha in the QML fill *and* the
  `quickshell-frosted-glass` layer rule in `~/.config/hypr/shehan/theming.lua`.
- **Material Icons ligatures break inside a Controls `Button`** — it propagates its own font
  onto `contentItem`, so `text: "close"` renders the literal word. Use a plain `Text` +
  `MouseArea`. The installed family is **Material Icons Round**; *Material Symbols Rounded*
  is not installed and fails the same silent way.
- **`highlighted` is FINAL on `Button`.** Shadowing it does not warn — it fails the entire
  Quickshell config to load, with the error pointing at the property rather than the cause.
- **Never call `StatusNotifierItem.display()` from a focus-grabbed panel.** It opens a
  separate compositor surface; taking focus clears the `HyprlandFocusGrab`, which closes
  the panel and the menu with it. Symptom: right-click does nothing, log is clean. Draw the
  menu inline off `QsMenuOpener` instead. `QsMenuEntry` is activated by emitting its
  `triggered` signal — there is no callable `activate()`.
- **`pkill -f <pattern>` matches the shell running it** if the pattern appears in that
  shell's own command line. Cost a terminal twice today. Use `pkill -x`.
- **`nm-applet` and `blueman` are masked** via `Hidden=true` in `~/.config/autostart/`.
  That also removed NetworkManager's secret agent and BlueZ's pairing agent — see
  `BACKLOG.md`.
- **Commit authorship is enforced** by `.githooks/commit-msg`, enabled through
  `core.hooksPath`. `install.sh` sets it; a fresh clone needs it set again.

## Settings files this repo writes

| Path | Holds |
|---|---|
| `~/.config/waybar-control-center/claude-usage.json` | usage dial display options |
| `~/.config/waybar-control-center/notifications.json` | DND flag |
| `~/.config/waybar-control-center/control-center.json` | per-section collapse state |
| `~/.cache/waybar-control-center/notification-history.json` | notification history across restarts (capped at 50) |

These are what the settings app edits. Each panel already watches its own file through a
`FileView`, so the settings app never has to talk to the running shell — and that contract
is what lets the UI move to another repo without either side noticing.

## The settings app — moving to hyprsys, do not extend it here

**`settings/` is being absorbed by [hyprsys](https://github.com/msfrox/hyprsys) in its
phase 3.** It still works and is still installed; nothing is deleted until that lands. But
no new settings UI is built in this repo — see PLAN.md, "The settings app, moved out".

Both unfinished phase-9 items are **done** (2026-08-06). This repo's half was making the
state reachable: `ControlCenterApp` reads `hiddenSections` / `hiddenActions` from
`control-center.json` and publishes a `sections` / `actions` catalogue of what it contains,
read off its own live children rather than hand-maintained beside them. hyprsys renders the
switches. Turning Waybar modules on and off is hyprsys's side entirely — it comments the
module's line out of the theme's `config`.

**If you add a section or a quick-action tile, do nothing else.** The catalogue is derived
from the live children, so it publishes itself and the setting appears in hyprsys.

`settings/` — a standalone **GTK4/libadwaita** app, not a Quickshell panel.
`install.sh` symlinks it to `~/.local/bin/waybar-control-center-settings` and installs a
`.desktop` entry; the Control Center's **Settings** quick action opens it.

```bash
waybar-control-center-settings --page waybar
```

It edits the files above and nothing else — no IPC, no daemon. Requires
`python-gobject`, `gtk4`, `libadwaita`; `install.sh` warns if they are missing.

Read [docs/settings.md](docs/settings.md) before touching it. The two things that will bite:
`modules.json` is JSONC **owned by ML4W** and is edited by targeted text replacement so its
176 comments survive; and it is parsed with a scanner, not a regex, because the regex
version looked correct and silently parsed nothing (real comments in it contain quotes).

## Next

**Not the settings app** — it moved to hyprsys phase 3, along with its two unfinished
items — all now done. See PLAN.md, "The settings app, moved out".

Nothing is blocking hyprsys any more. `settings/` here still works and is still installed;
deleting it and repointing the Control Center's Settings tile at `hyprsys` is a deliberate
later step.

Everything else is in `BACKLOG.md`.
