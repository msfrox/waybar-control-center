# The settings app

A standalone GTK4 / libadwaita application at `settings/`. `install.sh` symlinks it to
`~/.local/bin/waybar-control-center-settings` and installs a `.desktop` entry; the Control
Center's **Settings** quick action opens it.

```bash
waybar-control-center-settings              # opens on the first sidebar page
waybar-control-center-settings --page waybar
```

## Why it is not a Quickshell panel

The obvious thing was a seventh `PanelWindow`. Three reasons it is not:

- **Cost.** The shell runs all day; this gets looked at once a month. A settings UI
  instantiated at login costs memory and startup time every session for something almost
  never opened. As a separate process, opening it is a spawn and closing it frees
  everything.
- **It is going to grow.** This is meant to become the control surface for the session as a
  whole, not just these panels. That is a different lifetime and a different shape from a
  slide-in popup.
- **A settings UI is a solved problem in libadwaita.** `PreferencesPage`, `SwitchRow`,
  `SpinRow`, `EntryRow`, `ComboRow` are exactly the widgets needed, already keyboard- and
  screen-reader-correct. Rebuilding them in QML would be the whole job.

## It edits files, it does not talk to the shell

There is no IPC and no daemon. Each panel already owns a settings file and already watches
it through a Quickshell `FileView`, so **writing the file is applying the setting**.

| Path | Owner |
|---|---|
| `~/.config/hyprbar/notifications.json` | notification centre — DND, popup timeouts (now edited from hyprsys, not here) |
| `~/.config/hyprbar/control-center.json` | Control Center — collapse state |
| `~/.config/hyprbar/claude-usage.json` | usage dial |
| `~/.cache/hyprbar/notification-history.json` | notification history (not edited here) |
| `~/.config/waybar/modules.json` | **ML4W's** — see below |

The consequence worth stating: if this app is never installed or never launched, everything
keeps working exactly as it does now. It is an adjustment surface, not a dependency.

Writes are atomic — temp file in the same directory, then rename. A panel is watching, and
`FileView` reacts to a parse error by falling back to defaults, so a half-written file looks
exactly like "the user reset everything".

## Controls are chosen from the value's type

`schema.py` splits settings in two:

- **Described** — a hand-written `Field` with a label, a help line and a range. Small, and
  the only thing to touch when a setting is worth explaining.
- **Inferred** — everything else. `bool → SwitchRow`, `int/float → SpinRow`,
  `str → EntryRow`, described choices → `ComboRow`. Anything else (a nested object, a list)
  renders **read-only**: guessing a widget for an unknown shape risks writing the wrong
  structure back into somebody else's config.

That is what makes the Waybar page work without a form per module.

## The Waybar page

Generated entirely from `~/.config/waybar/modules.json` — every module, every key. Adding a
module to that file makes it appear here with no code written.

Two things make that file special, and both are handled in `store.py`:

**It is JSONC.** Comments and trailing commas. It is parsed with a small scanner rather
than a regex, because the regex version *looked* right and silently parsed nothing — real
comments in that file contain quotes and colons:

```
// "scroll-step": 1, // %, can be a float
```

Any one-line pattern either stops at the quote or eats into the next string. Tracking
string state is the only correct version, and it is barely longer.

**It belongs to ML4W.** Re-serialising it would delete all 176 comments in it, including
the deliberately commented-out modules that are there as documentation. So edits are
**targeted text replacements** on the original bytes: find the module's brace-matched span,
find exactly one `"key": <scalar>` line in it, replace that line. If the key cannot be
located unambiguously the write is **refused** and the UI says so — refusing beats
rewriting the wrong line in a file this project does not own.

Verified round-trip on a copy: one key changed, one line changed, all 176 comments and the
exact line count preserved.

Waybar does not reload on its own. Changes need `~/.config/waybar/launch.sh`.

## Not done yet

- Control Center section visibility and the quick-action list are still compiled into the
  QML. Making them data-driven is the next step and the reason that page currently only
  shows collapse state.
- Adding and removing Waybar modules, and reordering them in the theme's `config`. Only
  editing existing keys works today.
- The audio, network and bluetooth panels have no settings files — they are live device
  state — so those pages are placeholders.
