# Patches to ML4W's own Quickshell files

These files ship with the [ML4W dotfiles](https://github.com/mylinuxforwork/dotfiles),
so this repo does not carry copies of them — replacing them wholesale would fight the
next ML4W update. The changes are small and listed here instead.

Paths are relative to `~/.config/quickshell/`.

---

## `CustomTheme/Theme.qml` — load the Matugen palette at startup

**Symptom:** every Quickshell window (calendar, power menu, sidebar, statusbar) comes up
in a palette that has nothing to do with the wallpaper — on this machine a maroon card on
a teal bar — and only corrects itself after the next wallpaper change.

**Cause:** `Theme.qml` holds a hardcoded fallback palette and a `Process` that reads the
real one from `~/.config/ml4w/colors/colors.json`. That process is never started at
startup: `Component.onCompleted: reloadTheme()` is commented out and the `Process` has no
`running: true`. The only thing that ever runs it is the Matugen post-hook
(`qs ipc call theme-manager reload`, fired from `ml4w-wallpaper` and
`ml4w/listeners/gtk-theme-switcher.sh`) — and that fires on *change*, not on login.

**Fix:** uncomment the last line.

```qml
    // Load the JSON colors automatically when Quickshell starts.
    Component.onCompleted: reloadTheme()
}
```

Verify:

```bash
python3 -c "import json;d=json.load(open('$HOME/.config/ml4w/colors/colors.json'));print(d['primary'])"
```

should match what the calendar actually draws with.

---

## `shell.qml` — swap ML4W's calendar for the notification centre

`CalendarApp` is no longer used. The calendar now lives inside this repo's
`NotificationCenterApp`, together with the clock and the notification list, because all
three had to share one surface — see [notifications.md](notifications.md).

```qml
// was: import "CalendarApp"
import "NotificationCenterApp"

    // was: CalendarWindow {}
    NotificationCenterWindow {}
    NotificationToasts {}
```

Every other app in this repo is added to `shell.qml` the same way: one `import "<App>"`
line and one instantiation inside `ShellRoot`.

---

## `shell.qml` — register the shared panel look

```qml
import "Panels"
```

**Nothing is instantiated from it.** The import line exists purely to make the module
importable, and without it every consumer fails to load with

```
module "qs.Panels" is not installed
```

**Why:** a directory under `~/.config/quickshell/` only becomes addressable as
`qs.<Name>` once something has pulled it in with a *relative* import — and every file
that wants `qs.Panels` (`BarApp/PowerPopout.qml` in hyprbar, `ControlCenterApp`) lives
inside a **symlinked** directory, where a bare `qs.Panels` does not resolve on its own.
`qs.CustomTheme` and `qs.NotificationCenterApp` have always worked from those same
symlinked directories for exactly this reason: `shell.qml` already imports both
relatively. This is the same one-line registration, for a module with no window.

Verified by bisection in a throwaway `qs -p` config: `qs.X` resolves from a real
subdirectory unaided, fails from a symlinked one, and starts working the moment the
root does `import "X"`.

[Panels/README.md](../quickshell/Panels/README.md) is what the module is.

ML4W's `CalendarApp/` is left on disk untouched. Nothing references it, and deleting it
would only give the next ML4W update something to restore.

---

## `~/.config/hypr` — stop swaync so Quickshell can own the bus name

Not a Quickshell file, but the same class of problem: `conf/autostart.lua:46` starts
swaync, and `~/.config/hypr` is a symlink into `~/.mydotfiles/com.ml4w.dotfiles`, so
editing that line gets reverted on the next update.

`~/.config/hypr/shehan/notifications.lua`, required from `custom.lua` (which loads last
and the updater never touches), lets ML4W start swaync and then kills it in a loop.

This half only covers the *directly execed* swaync. The one that keeps coming back is
D-Bus activated, and it is `install.sh`'s `systemctl --user mask swaync.service` that
stops it — including the activation triggered from inside our own shell by ML4W's
`StatusbarApp/SwayncModule.qml`, which runs `swaync-client -swb`.
[notifications.md](notifications.md) has the full chain.

`StatusbarApp/` is left untouched for the same reason as `CalendarApp/` above: the mask
already makes its `swaync-client` call a no-op, and editing an ML4W-owned file only gives
the next update something to restore.

---

## `~/.config/waybar/modules.json` — the clock opens the notification centre

```json
  "clock": {
    "on-click": "qs ipc call notifications toggle",
  }
```

Waybar does not pick this up until the bar is restarted: `~/.config/waybar/launch.sh`.
