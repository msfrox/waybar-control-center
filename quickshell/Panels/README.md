# `qs.Panels` — the shared look for every panel and popout

One import, one config. Everything this desktop pops up — the control centre,
the audio/bluetooth/network panels, the notification centre, and the bar's own
popouts over in [hyprbar](https://github.com/msfrox/hyprbar) — draws its
surface, its rows and its controls from here.

```qml
import qs.Panels

PanelCard {
    Section {
        title: "POWER PROFILE"
        StatRow { glyph: ""; label: "Charging at"; value: "+31.2 W" }
        ToggleRow { label: "Keep awake"; checked: root.awake
                    onToggled: (v) => root.setAwake(v) }
    }
}
```

## Why it exists

The surface language used to be copied by hand into every window that drew one,
and it had drifted: card alpha was `0.30` in the control centre, `0.88` in the
power popout, `0.72` in the quicklinks drawer and `0.40` in the player stack,
across three different corner radii. Every one of those numbers had a reason at
the time and no single reader could see all of them at once.

Now there is one number and one place to change it.

## What lives where

| | |
|---|---|
| `PanelStyle.qml` | **the config.** Every dimension, alpha, duration and derived colour. Edit this and everything moves. |
| `PanelCard.qml` | shadow + translucent card + padded content column |
| `Section.qml` | a titled, optionally collapsible block with a divider |
| `SectionLabel.qml` / `Separator.qml` | the heading and the rule, on their own |
| `StatRow.qml` | marker · label · value (· note) |
| `ToggleRow.qml` | label, sub-label, switch |
| `SliderRow.qml` | marker · slider · readout |
| `ActionButton.qml` | small glyph-and-label button, `destructive` variant |
| `Glyph.qml` / `FaGlyph.qml` | Material Icons Round / Font Awesome at weight 900 |

**`PanelStyle` is not a palette.** Colours still come from `Theme` (Matugen,
i.e. the wallpaper). What lives here is how those colours are *used* — which
role goes on a card, at what alpha, behind what. If a value would have to change
when the wallpaper changes it belongs in `Theme`; if it describes the shape of
the UI it belongs here.

## Adding a component

If you write the same `Rectangle` twice, it wants to be a file in this
directory. Rules that keep the set coherent:

- **No literal numbers or colours.** Everything comes off `PanelStyle`. A
  component that hardcodes `radius: 8` is a component that will not follow the
  next change.
- **State is an input, never owned.** `ToggleRow.checked` is set by the caller
  and the row emits `toggled`; it does not flip itself. That is what lets the
  real state live in one settings file with one writer.
- **Attached `Layout.*` properties belong on the component root**, so a consumer
  can drop it straight into a `ColumnLayout` without wrapping it.

## Gotchas already paid for

- **A `Slider`'s `value` binding dies on the first drag.** `SliderRow` re-asserts
  it on every new input except while the handle is held. Do not remove that
  `Connections` block.
- **Font Awesome needs `font.weight: 900`.** Four glyphs this desktop uses exist
  only in the Solid-900 face and fontconfig resolves the family to Regular-400,
  which renders them as tofu. That is the whole reason `FaGlyph` exists.
- **A missing Material Icons ligature renders as the literal word**, not tofu.
  Check a new glyph name actually draws.
- **Keep `panelAlpha` above `0.2`.** Hyprland's `quickshell-frosted-glass` layer
  rule carries `ignore_alpha = 0.2`; below that the frost silently stops
  applying and the card goes flat.
- **The shadow must stay in the transparent gutter** (`PanelCard.shadowMargin`),
  not become a layer effect on the card, or the same blur rule frosts a
  rectangle of wallpaper the size of the blur radius around every popup.
