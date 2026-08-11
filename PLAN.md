# Plan

## Why this repo exists

The Waybar setup on this machine had grown past what Waybar alone can express. Waybar
modules are GTK widgets fed by text or JSON — one click handler, one tooltip, no panel.
Anything richer (a volume mixer, a usage dial, a control centre) has to live somewhere
else and be *triggered* from the bar.

The ML4W dotfiles already ship the vehicle for that: a Quickshell shell
(`~/.config/quickshell/shell.qml`) hosting layer-shell windows — welcome, power, sidebar,
calendar, wallpaper — each with an `IpcHandler`, so a Waybar module opens one with
`qs ipc call <target> toggle`. Every panel-shaped feature below reuses that pattern
rather than inventing a new one.

The prior investigation (KB: *COSMIC panel applets under Hyprland*) ruled out the
alternative: **Waybar cannot embed a foreign Wayland surface**, and there is no bridge
project. A COSMIC applet run standalone is an xdg toplevel, which Waybar's `top` layer
draws over. So "bring the COSMIC applet into Waybar" means **re-implement the UI**, and
Quickshell is where that happens.

## Architecture

```
Waybar module  ──(qs ipc call)──▶  Quickshell PanelWindow (WlrLayer.Overlay)
   thin label                        the actual UI, themed from CustomTheme
```

Shared conventions for every panel added here, taken from the existing ML4W windows:

- `PanelWindow` + `WlrLayershell.layer: WlrLayer.Overlay`, `exclusionMode: Ignore`
- `HyprlandFocusGrab` for click-outside-to-close, `Shortcut { sequence: "Escape" }`
- an `isOpen` bool driving an animated margin, with a `showWindow` guard so Wayland
  does not unmap the surface before the hide animation finishes
- `IpcHandler` exposing `toggle` / `open` / `close` / `isOpen`
- colours from `qs.CustomTheme` (which follows Matugen, i.e. the wallpaper)

## Phases

- [x] **Phase 0 — repo groundwork.** ✅ Scaffold, licence, hooks, install script, first push.
- [x] **Phase 1 — calendar to bottom-right.** ✅ Re-anchor `CalendarWindow` from
      top-centre to bottom-right, above the bar. One-file change; do it first because it
      confirms the anchor/margin maths every later panel depends on.
- [x] **Phase 2 — app launcher button.** ✅ Move `custom/appmenu` from `modules-left` to
      `modules-center`, drop the pill, give it a distinct launcher icon.
- [x] **Phase 3 — audio popup.** ✅ (plus bluetooth + network, unplanned) New `AudioApp` Quickshell window driven by
      `Quickshell.Services.Pipewire`: output slider, input slider, device switching,
      per-app streams. `pulseaudio`'s `on-click` opens it; `pavucontrol` moves to
      right-click.
- [x] **Phase 4 — Claude usage dial.** ✅ Replace the glyph badge with a rendered dial —
      weekly window as the ring, the 5-hour session as the pie fill in 10% steps — served
      to Waybar's `image` module. Add a `ClaudeUsageApp` popup carrying the options
      YapCap exposes (panel style, used vs. remaining, relative vs. absolute reset,
      refresh interval).
- [x] **Phase 5 — Control Center.** ✅ New `ControlCenterApp` side panel with a section
      framework: calendar, system usage, system tray (`Quickshell.Services.SystemTray`),
      quick toggles. One Waybar button opens it. Groundwork first — migrating individual
      modules into it is incremental afterwards.
- [x] **Phase 6 — brightness, fans, wider tiles.** ✅ Internal and external (DDC/CI)
      brightness sliders, fan speeds, three-across info tiles, scroll view dropped.
- [x] **Phase 7 — rename.** ✅ `Waybar-modules` → `waybar-control-center`: repo, checkout,
      and the `$XDG` settings/cache directories. `install.sh` migrates the old ones once.
- [x] **Phase 8 — Quickshell becomes the notification daemon.** ✅ `NotificationCenterApp`:
      clock over calendar over the notification list in one bottom-right card, plus toast
      popups and a `NotificationState` singleton. Replaces both ML4W's `CalendarApp` and
      swaync. Also fixed frosted glass, which had never actually worked anywhere. Details
      in [docs/notifications.md](docs/notifications.md).
- [x] **Phase 9 — the settings app. ✅ Closed here; moved to hyprsys.** Scaffolded and
      working: a standalone GTK4/libadwaita app at `settings/`, launched from the Control
      Center's Settings tile. Notifications, usage dial and a fully generated Waybar page
      all edit real files. The two unfinished pieces — Control Center
      section/quick-action editing, and Waybar module add/remove — **moved to
      [hyprsys](https://github.com/msfrox/hyprsys) phase 3 together with the app itself**.
      See [the settings section below](#the-settings-app-moved-out) before doing any
      further settings work in this repo.
- [x] **Phase 10 — Quickshell becomes the bar. ✅ Started here; moved to
      [hyprbar](https://github.com/msfrox/hyprbar).** Two steps shipped in this repo — the
      frame and the built-in module replacements — then the bar left, the same way the
      settings app did and for the same reason: it had stopped being a Waybar accessory.
      `quickshell/BarApp/` and its history moved out via `git subtree split`.
      See [the bar section below](#the-bar-moved-out) before doing bar work here.

### Scope contracts

**Phase 4 — the dial.** Waybar's `custom/` modules cannot draw. Waybar's `image` module
can: it takes an `exec` whose stdout is `path\ntooltip\nclass`, and renders the file at
`size` px. So the dial is a PNG regenerated on each refresh (pycairo — `librsvg`'s
gdk-pixbuf loader is not guaranteed present, so SVG straight into the image module is not
safe). Two rings, one image:

- outer arc, thick, swept clockwise = 7-day window utilisation
- inner disc, filled pie-style, quantised to 10% = current 5-hour block

**Phase 5 — the Control Center.** The point of this phase is the *frame*, not the
contents: a right-anchored full-height panel, a scrollable column of collapsible
sections, and a section component other modules can be dropped into later. The initial
fill is calendar + system usage + tray, because those are the three the bar most wants
to shed.

**Phase 9 — the settings app.** The Control Center is becoming the control surface for the
whole session, and every panel it fronts has settings that currently only exist as hand-
edited JSON. The point of this phase is an *adjustment surface*, not a new runtime:

- **Its own process**, launched on demand, not another window in `shell.qml`. A settings UI
  instantiated at login costs memory and startup time every session to be looked at once a
  month. Opening it is a spawn; closing it frees everything.
  *Built as GTK4/libadwaita, not Quickshell.* Two reasons beyond cost: this is meant to grow
  into the control surface for the whole session, which is a different lifetime from a
  slide-in popup; and libadwaita already ships the exact widget set a settings UI needs, so
  rebuilding `PreferencesPage`/`SwitchRow`/`SpinRow` in QML would have been the whole job.
  (Note `qs -c settings` would not have worked anyway: with `~/.config/quickshell/shell.qml`
  present, Quickshell registers it as the only config and ignores subdirectories.)
- **It edits files, it does not hold state.** Each panel keeps owning its own settings file
  under `~/.config/waybar-control-center/`. The settings app reads those files, writes them
  back, and the panels pick the change up through the `FileView` watch they already have.
  Nothing in the running shell has to know the settings app exists.
- **Sections:** Control Center (which sections are shown, which metrics, which quick
  actions), plus one per panel — audio, bluetooth, network, notifications, usage dial.
- **A Waybar section driven off `modules.json` itself.** Add/remove/enable modules, and for
  per-module settings do *not* hand-write a form per module: read the JSON, list each key
  with its current value, and pick a control from the value's type — bool → toggle, number →
  spin box, string → text field, array → list editor. New modules then need no new code.

Deliberately out of scope: anything that makes the settings app a dependency of the running
shell. If it is not installed or not launched, everything must keep working exactly as it
does now.

**Phase 10 — the bar.** Its scope contract moved with it to [hyprbar](https://github.com/msfrox/hyprbar)/PLAN.md, which is now the record for
why the bar is its own app rather than ML4W's `StatusbarApp`, why `Variants` was
there from the start, and what Waybar structurally could not do. See
[the bar section below](#the-bar-moved-out) for what stayed behind.

## Constraints

- `~/.config/waybar/config` does not exist. The live pair is chosen by
  `~/.config/ml4w/settings/waybar-theme.sh` → `~/.config/waybar/themes/ml4w-modern/`.
  Confirm with `ps aux | grep '[w]aybar -c'`.
- `modules.json`, the theme `config`, and `style.css` are **ML4W-owned**. This repo ships
  snippets for them, never overwrites them.
- The Claude usage module's `font-size` used to set the whole bar's height — Waybar
  measures the bar from its tallest child. Moving it to an `image` module removes that
  coupling, but check `hyprctl monitors -j` → `reserved[3]` after the change regardless.

## Done, and what changed along the way

Phases 0–8 shipped. Things that were not in the original plan and were added mid-flight at
the owner's request:

- **Bluetooth and network panels.** Once the audio panel existed, the case for keeping
  blueman's and nm-applet's tray menus scraped through rofi collapsed — those broke
  whenever the tray icon was closed. Both applets are now masked.
- **Frosted glass.** One Hyprland layer rule on the `quickshell` namespace, plus alpha in
  each card's fill.
- **Matugen at Quickshell startup.** `Theme.qml`'s palette loader was commented out, so
  every Quickshell window came up on a hardcoded fallback palette until the next wallpaper
  change. That was the actual cause of "the calendar doesn't match the theme".
- **Owning the notification daemon** (phase 8). Originally parked in the backlog as "its own
  phase, not a patch", and the plan of record was to keep swaync and stack two windows. That
  inverted once `Quickshell.Services.Notifications` turned out to be a complete API — see
  [docs/notifications.md](docs/notifications.md).

### The frosted glass that was never frosted

Worth its own note, because it survived five panels and several attempts to fix it.

Every card was a `Rectangle` with a vertical `gradient:` and a translucent `Rectangle`
inset 2px inside it. A QML gradient is a **fill**, not a border — it painted the whole
card, so the inner rectangle's alpha composited against *it* rather than against the
wallpaper. The cards were opaque and always had been.

The diagnostic that settled it: set the inner fill's alpha to `0.0` and screenshot. If the
card looks identical, nothing behind it was ever showing through. Rectangle has no gradient
border, so the fix was to drop the gradient and use one rectangle with a translucent fill
and a hairline `border`.

## The settings app, moved out

The settings UI is leaving this repo. It grew out of the scope this project is good at.

The phase-9 scope contract above says the settings app "is meant to grow into the control
surface for the whole session" — and once that was taken seriously, it stopped being a
Waybar accessory. The settings a laptop actually needs first are power, lid, idle, lock,
night light, theming, fonts, default apps and autostart, none of which this repo has any
business owning: they are not panel state and not Waybar config. That app is
[**hyprsys**](https://github.com/msfrox/hyprsys), and it absorbs `settings/` wholesale in
its phase 6.

**What that means for work in this repo:**

- **Do not build new settings UI here.** Not a page, not a field, not a new backing file
  format. If a panel needs a new option, add the setting *file* it reads and stop there —
  the UI for it belongs in hyprsys.
- **The QML side of the two unfinished items is done** (2026-08-06). `ControlCenterApp`
  now reads `hiddenSections` / `hiddenActions` out of `control-center.json`, and
  **publishes a catalogue** — `sections` and `actions`, read off its own live children —
  so hyprsys can offer them without keeping a second copy of the list. Turning Waybar
  modules on and off is handled entirely in hyprsys, by commenting their line out of the
  theme's `config`. Module *reordering* is still not offered anywhere.
- **`settings/` stays here and keeps working until it is deliberately removed.** Nothing is
  deleted early; the Control Center's Settings tile keeps opening it. When phase 6 ships,
  `settings/` is deleted and the tile launches `hyprsys` instead.
- **The audio, network and bluetooth placeholder pages are not coming back.** They front
  live device state with no settings file behind them, which is why they were empty.
  hyprsys phase 6 does them properly against NetworkManager, BlueZ and PipeWire.

## The bar, moved out

Phase 10 replaced Waybar with a Quickshell bar. Two steps shipped here — the frame
(`PanelWindow` under `Variants`, exclusion zone, the three module groups, the pure-button
modules and the clock) and the built-in replacements (`ext/workspaces`, battery off
`Quickshell.Services.UPower`, and the volume / Bluetooth / network indicators).

Then it left, for the same reason the settings app did: it had stopped being a Waybar
accessory. A bar is not a panel-backed Waybar module, it has its own phases, its own
settings file and its own body of detail about how GTK sizes a pill and which font
actually carries a glyph. It lives at [**hyprbar**](https://github.com/msfrox/hyprbar),
with the two phase-10 commits carried over by `git subtree split`.

**What that means for work in this repo:**

- **Do not add bar modules here.** `quickshell/BarApp/` is gone and
  `~/.config/quickshell/BarApp` is symlinked from hyprbar now. This repo's `install.sh`
  loops over `quickshell/*/`, so it simply no longer manages it.
- **The split is organisational, not a decoupling.** hyprbar opens *this* repo's panels
  over `qs ipc call` and takes its palette from the same ML4W `CustomTheme` singleton, so
  both must be installed. Renaming an IPC target here breaks the bar.
- **The Claude dial is still half here.** hyprbar's phase 5 redraws it as a `Canvas`,
  which is what finally deletes the PNG/signal-8 pipeline from
  `waybar/scripts/claude-usage.py`. Until then that script stays as it is.
- **`bar.json` still lives under this repo's settings directory**
  (`~/.config/waybar-control-center/bar.json`). Left there deliberately: moving it would
  strand the existing file for no gain, and hyprsys reads the directory, not the repo.

## Next

The panels in this repo are feature-complete for now; the active work is in hyprbar
(phase 3, the centre taskbar) and hyprsys (phase 3, absorbing `settings/`).

What remains here is triggered by those: deleting `settings/` and repointing the Control
Center's Settings tile at hyprsys when hyprsys phase 6 lands, and stripping the PNG
pipeline out of `claude-usage.py` when hyprbar phase 5 lands.

Everything else is in [BACKLOG.md](BACKLOG.md).
