# Handoff

**State: phases 0–8 shipped; phase 10 (the Quickshell bar) is at step 2 of 7, done.**
Repo: `msfrox/waybar-control-center` (public). Everything is symlinked into `~/.config`
by `install.sh`, so editing the repo edits the live desktop.

**Both bars run at once right now**: `BarApp` is anchored to the *top* (`position: "top"`
in `bar.json`) and Waybar still owns the bottom, so the two can be screenshot and compared
directly. `hyprctl monitors -j` shows `reserved: [0, 52, 0, 52]` while that is true.
Compare with `grim -g "0,0 1920x52"` (ours) and `grim -g "0,1148 1920x52"` (Waybar's).

Steps 1–2 are done: the frame, `BarButton`, the app-menu / Control Center / ML4W-logo
buttons, the clock, `ext/workspaces`, battery, and the volume / Bluetooth / network
indicators. They measure pixel-equal to their Waybar originals (see *Matching Waybar's
geometry* below). Step 3 is the taskbar.

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

`quickshell/BarApp/` is the bar: `BarWindow` (frame + module groups), `BarButton` (the
shared module base), and `Clock` / `Workspaces` / `Volume` / `Bluetooth` / `Network` /
`Battery` modules. Backends in `waybar/scripts/`.

IPC targets: `qs ipc show`. This repo owns `audio`, `bluetooth`, `network`,
`claude-usage`, `control-center`, `notifications`, `notification-state`, `bar`.

## Porting a Waybar module to `BarApp` — read this first

- **The `colored` variant remaps four colour names before importing the shared sheet**
  (`themes/ml4w-modern/colored/style.css:5-8`): `on_surface`→`on_secondary`,
  `background`→`secondary`, `border_color`→`secondary`, `icon_color`→`on_secondary`.
  So `#clock { background: @background; color: @on_surface }` is really a **light** pill
  with **dark** text. Resolve through that table first, then map to `Theme.*`.
  On *bare* modules use `Theme.on_surface` — it is the genuine Matugen value, not the
  variant's override, and equals `@bar_fg` (`#dde4e3`) exactly.
- **A module's "icon" is not always text.** `custom/ml4w-welcome`'s `format` is a single
  space; the logo arrives as a CSS `background-image`. Check the CSS for one before
  assuming the format string is the whole module.
- **Bare modules hover by recolouring to `@primary`, not by showing a plate.** Pills are
  the ones that change fill.
- **Never put `anchors` on an item inside a `RowLayout`.** Qt warns and then sizes it
  arbitrarily. Use `Layout.alignment` / `Layout.*`.
- Waybar's `config` sets `spacing: 0` and expresses every gap as a per-module CSS margin,
  so `BarButton.rightMargin` is the only place a gap belongs.

### Fonts — the trap that looks like a QML bug

Waybar draws each status module as ONE label mixing text with Font Awesome private-use
codepoints, resolved by a CSS font-family **chain**. Neither Qt equivalent works:

- **Quickshell 0.3.0 rejects `font.families`** ("Cannot assign to non-existent property"),
  even though plain Qt 6.11 accepts it. Verified with a minimal `qs -p` config.
- **Automatic fontconfig fallback is not a substitute.** Four glyphs this bar needs —
  `U+F6A9` muted, `U+F796` network-wired, `U+F5E7` charging bolt, `U+F590` headset —
  exist in exactly ONE installed font, Font Awesome 7 Free, whose only file is the
  **Solid-900** face. Fallback resolves the family to a Regular-400 face that genuinely
  lacks them, so they render as tofu. `<font face=…>` in StyledText fails identically,
  because a face attribute cannot carry a weight.

`font.weight: 900` is the fix. `BarButton` splits `label` into private-use vs text runs
and renders icon runs in `iconFamily` at 900 — so modules still set one `label` to
Waybar's format string verbatim, including those that put an icon *after* the text.
Qt falls back to FA **Brands** for `U+F293`/`U+F294` under that same request, so one
family covers everything.

Two corollaries:

- **Text runs need `font.weight: Font.DemiBold`.** "Fira Sans Semibold" names a *style*
  inside the Fira Sans family; asking for it by family name and pinning weight 400 gets
  the Regular face, which measured 12px narrower than the same string on Waybar.
- **Raw private-use characters do not survive being written to a file** — they were
  silently stripped from a heredoc, a source comment and two agent-written modules.
  **Always write `\uXXXX` escapes.** Check with a byte scan, not by eye: `Read` renders
  these characters as blank, so a stripped glyph and a present one look identical.

### Matching Waybar's geometry

GTK sizes a pill from its **content** and never stretches it to the bar. Deriving height
from `parent.height` gave 46px pills against Waybar's 34.7px, which touched the bar edges
and was the most obvious "this isn't Waybar" tell. Measured off the live bar:

| | Waybar | meaning |
|---|---|---|
| pill height | 34.7px in a 52px bar | 8.7px gap above and below |
| active ws pill | 46.7px | CSS `min-width: 30` + 12 padding + 4 border |
| inactive ws pill | 32.7px | **16** + 12 padding + 4 border |

That **16 is GTK Adwaita's default `button { min-width }`**. The theme sheet never
restates it, so it is invisible in the CSS and is why a pill sized purely from its label
comes out ~12px too narrow.

**`min-width` on a container is not `Layout.minimumWidth`.** GTK widens the container and
leaves the slack empty; a RowLayout forced past its content width hands the slack to its
*items*, which pushed the workspace pills 17px apart against Waybar's 6px. A trailing
`Item { Layout.fillWidth: true }` absorbs it.

## Live gotchas

- **Never name an `IpcHandler` function `show`.** `qs ipc call bar show` is swallowed by
  the CLI's own `ipc show` subcommand: it prints the handler listing, exits 0, and never
  reaches QML. Ours is `enable`/`disable` now, which is also what ML4W's `statusbar`
  handler uses. Assume any other CLI verb is booby-trapped too.
- **PipeWire node properties do not carry `device.form_factor` or the active port.** Both
  live on the *device*, so Waybar's per-port `format-icons` (headset/headphone/car…)
  cannot be resolved the way Waybar does it. `VolumeModule` keys off `device.api ==
  "bluez5"`, which IS on the node; the cost is that a Bluetooth *speaker* would also draw
  as a headset.
- **Waybar's `network` signal reading goes stale.** It showed 33–40% while `nmcli` and
  our module both read ~48%. Ours is live off `Quickshell.Networking`; a difference here
  is Waybar being wrong, not us.
- **`signalStrength` is a 0..1 double**, verified against `nmcli` and NetworkManager's
  D-Bus `AccessPoint.Strength` at the same instant. Scale by 100 for Waybar's `{}%`.
- **No icon font here has a three-wave speaker.** Font Awesome and Material Design both
  stop at two (`volume-off` / `-low` / `-high`), so the volume ramp is three steps, not
  four. This is the one place `BarApp` knowingly deviates from `modules.json` — Waybar's
  own array duplicates its top glyph and only ever shows two pictures.
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
| `~/.config/waybar-control-center/bar.json` | bar enabled / position / height (phase 10) |
| `~/.cache/waybar-control-center/notification-history.json` | notification history (capped at 50) |

Each panel watches its own file through a `FileView`, so nothing has to talk to the
running shell — that contract is what let the settings UI move to another repo.

## The settings app — moving to hyprsys, do not extend it here

`settings/` is being absorbed by [hyprsys](https://github.com/msfrox/hyprsys) phase 3. It
still works and is still installed; nothing is deleted until that lands. **No new settings
UI is built in this repo** — see PLAN.md, "The settings app, moved out". If a panel needs
a new option, add the setting *file* it reads and stop there.

## Next

**Phase 10 step 3 — the taskbar**, off `Quickshell.Wayland` toplevels +
`DesktopEntries.heuristicLookup()`, grouped by workspace like the Waybar original.
Then step 4 (window title, Mpris nowplaying, quicklinks — PLAN.md has the quicklinks
structure, which is *not* in `modules.json`), 5 (the Claude dial as a `Canvas`),
6 (cutover), 7 (the Waybar-blocked wins).

Two things not to lose:

- **`qs ipc call` per click is a placeholder.** `BarApp.panel()` spawns a process to talk
  to a window in its own process. Worth replacing with an in-process signal bus when the
  panels are being edited anyway — deliberately not done yet so every trigger behaves
  identically to the Waybar one it replaces.
- **hyprsys's generated Waybar page dies with Waybar.** It is driven off `modules.json`;
  once the bar is `BarApp`, `bar.json` is what there is to configure.

Everything else is in `BACKLOG.md`.
