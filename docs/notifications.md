# Notifications

Quickshell owns `org.freedesktop.Notifications` on this machine. swaync is installed but
masked and killed at login — see [Keeping swaync off the bus name](#keeping-swaync-off-the-bus-name),
which is the part that actually holds.

## Why swaync had to go

The layout wanted was one surface holding a large clock, a calendar, and the notification
list, opened by clicking the bar's clock. swaync cannot express that. Its control centre
takes a fixed list of widgets, and on 0.12.6 the complete set is:

```
notifications  title  dnd  label  mpris  buttons-grid  menubar  slider  volume
backlight  inhibitors
```

No clock, no calendar, no plugin API. `label` is static text, not a live clock.

The alternative considered first was two stacked surfaces pretending to be one — a
Quickshell card with clock and calendar, sitting directly above swaync's popup re-anchored
to the bottom right, both toggled by the same click. That was rejected once
`Quickshell.Services.Notifications` turned out to be a complete API rather than a stub:
owning the bus name is less work than co-ordinating two windows, and it makes the whole
thing one card.

## The pieces

| File | Holds |
|---|---|
| `NotificationState.qml` | the `NotificationServer`, the DND flag, arrival times, toast list, and the persisted history. A singleton because the toasts have to keep firing while the panel is closed and unmapped. |
| `NotificationCenterWindow.qml` | the bottom-right panel: clock, calendar, list. IPC target `notifications`. |
| `NotificationToasts.qml` | the bottom-right popups that replace the ones swaync drew. |
| `NotificationEntry.qml` | one notification, shared by the panel list and the toasts. |

The Control Center's Notifications section and its DND quick action read the same
singleton, so they no longer poll a subprocess.

## Keeping swaync off the bus name

Killing swaync is not enough, and for two weeks this repo pretended it was. **swaync is
D-Bus activatable.** `/usr/share/dbus-1/services` ships three service files for it:

```
org.erikreider.swaync.service      Name=org.freedesktop.Notifications   (yes, really)
org.erikreider.swaync.cc.service   Name=org.erikreider.swaync.cc
org.kde.plasma.Notifications…      (unrelated)
```

Every one carries `SystemdService=swaync.service`, so *anything that talks to swaync brings
the daemon back*, and the daemon then takes `org.freedesktop.Notifications` off Quickshell.
A `pkill` closes the process and leaves the door it came through wide open.

And there is such a talker inside our own shell: ML4W's
`~/.config/quickshell/StatusbarApp/SwayncModule.qml` runs `swaync-client -swb` to feed its
bell icon. That is the whole 2026-08-06 regression — the hypr-side `pkill` fired at t+4s and
won, then `qs` itself re-activated swaync eight seconds later:

```
04:16:24  qs starts, acquires org.freedesktop.Notifications
04:16:2x  pkill -x swaync   (kills ML4W's directly-execed one)
04:16:32  systemd[898]: Starting Swaync notification daemon...   <- dbus activation, PPID 3456 = qs
```

So the fix has two halves, and both are needed:

| Half | Where | Stops |
|---|---|---|
| `systemctl --user mask swaync.service` | `install.sh` | every D-Bus activation path |
| `pkill -x swaync` on hyprland start | `~/.config/hypr/shehan/notifications.lua` | ML4W's direct `hl.exec_cmd("swaync")`, which execs the binary and walks past the mask |

**Why masking is the durable one.** It is a symlink to `/dev/null` in
`~/.config/systemd/user/`, so it survives a pacman update of swaync (which rewrites
`/usr/lib/systemd/user/` and `/usr/share/dbus-1/services/`) *and* an ML4W dotfiles update
(which rewrites everything under `~/.mydotfiles`). Those are the two events that reverted
every earlier attempt. Activation then fails loudly in the journal:

```
dbus-broker-launch[…]: Activation request for 'org.erikreider.swaync.cc' failed:
The systemd unit 'swaync.service' is masked.
```

Undo with `systemctl --user unmask swaync.service`. Nothing depends on swaync
(`pactree -r swaync` lists only itself), but leave the package installed — ML4W's installer
pulls it in again on every update, so uninstalling is a fight that masking already won.

**Quickshell re-acquires the name when the owner releases it.** Verified 2026-08-06:
stopping swaync handed `org.freedesktop.Notifications` straight back to the running `qs`
with no restart. This is why the ordering against Quickshell's own startup no longer
matters — the old `sleep 4` was tuned to lose to swaync as little as possible, and it turns
out losing is recoverable as long as swaync eventually dies. The hypr-side kill is now a
30 × 1s loop rather than one timed shot, because a cold boot can push ML4W's exec past any
fixed guess.

**`pkill -x`, not `pkill -f`.** The pattern `swaync-client` appears in the `sh -c` command
line running the pkill, so `-f` matches that shell and kills it before it gets there.

Check who owns the name with:

```bash
gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.GetServerInformation
```

`('quickshell', 'quickshell', '', '1.2')` is right. Anything mentioning swaync means the
mask came off — check `systemctl --user is-enabled swaync.service`, and re-run `install.sh`.

## Behaviour notes

- **Everything is tracked.** A `Notification` is destroyed the moment the `notification`
  signal handler returns unless `tracked` is set, and any reference kept to an untracked one
  dangles. Transient notifications (volume OSDs and the like) are tracked too, then
  dismissed when their toast expires, so they never reach the panel.
- **DND suppresses toasts, not notifications.** The panel still fills up, which is what
  swaync did and what makes DND safe to leave on. The DND flag is persisted
  (`~/.config/waybar-control-center/notifications.json`), and separately, so is the
  notification list itself — up to 50 entries in
  `~/.cache/waybar-control-center/notification-history.json`, debounced and written as
  plain snapshots (a `Notification` cannot be re-injected, so a restored entry is `historic:
  true`, carries no actions, and cannot be replied to).
- **Timeouts** mirror the old swaync config: 2s low, 4s normal, 6s critical, and a
  notification asking for its own timeout gets it. `expireTimeout == 0` means "until
  dismissed" and the toast timer is not armed at all.
- **Hovering a toast holds it open**, otherwise anything with an action button is a race.
- **Arrival times live in the singleton**, keyed by notification id — a `Notification`
  carries no timestamp of its own, so "5m ago" has to be recorded as they land.

## Gotchas that cost time

- **Material Icons ligatures inside a Controls `Button` render as the literal word.**
  `Button` propagates its own `font` onto `contentItem`, overriding the family set there,
  so `text: "close"` came out as the word "close". Glyph buttons are a plain `Text` plus a
  `MouseArea`. Note the installed family is **Material Icons Round** — *Material Symbols
  Rounded* is not installed, and a missing family fails the same silent way.
- **`highlighted` is FINAL on `Button`.** Shadowing it with a custom property does not warn,
  it fails to load the entire Quickshell config.
- **A `Repeater`/`ListView` bound straight to `NotificationState.toasts` cannot animate
  add or remove.** `toasts` is a `list<var>` reassigned WHOLESALE on every arrival and
  drop (`root.toasts = [...root.toasts, n]` / `.filter(...)`) — a new array each time,
  with no way for the view to tell "one item was appended" from "everything changed", so
  it tore down and rebuilt every delegate on every single notification. Existing toasts
  replayed their slide-in and a dismissed one just vanished; several arriving close
  together read as the whole stack flickering. Fixed by keeping a local `ListModel` in
  `NotificationToasts.qml`, diffed against `toasts` on every change (`append`/`insert`/
  `remove`, matched by `notification.id`) rather than reassigned — `ListModel` mutations
  fire real per-row signals, which is what `ListView`'s `add`/`remove`/`displaced`
  transitions need to exist at all. Did not change what the singleton stores; `toasts`
  has exactly one consumer.
