pragma Singleton

// THE ONE PLACE EVERY PANEL AND POPOUT GETS ITS LOOK FROM.
//
// Before this file the surface language was copied by hand into every window
// that drew one — ControlCenterWindow, AudioWindow, the bar's PowerPopout,
// PlayerStack, WindowPreview, the quicklinks drawer — and it had already
// drifted: the card alpha was 0.30 in the control centre, 0.88 in the power
// popout, 0.72 in the quicklinks drawer and 0.40 in the player stack, with
// three different corner radii between them. Each of those numbers had a
// defensible reason at the time and no single reader could see all of them.
//
// So: every dimension, alpha, duration and derived colour that makes a panel
// look like this desktop's panels lives here, once. Change a value in this file
// and every consumer moves together. Add a new popout, import `qs.Panels`, and
// it is already in the family without a design decision being made.
//
// THIS IS NOT A PALETTE. Colours still come from `Theme` (Matugen, i.e. the
// wallpaper) — what lives here is how those colours are USED: which role goes
// on a card, at what alpha, behind what. Anything that would have to change
// when the wallpaper changes belongs in Theme; anything that describes the
// shape of the UI belongs here.
//
//     import qs.Panels
//
//     PanelCard {
//         Section { title: "SOMETHING" ; StatRow { ... } }
//     }
//
// The components in this directory are the vocabulary; the tokens below are
// what they are built from. Reach for a component first — a raw `Rectangle`
// with `PanelStyle.fillSubtle` on it is fine, but if you write the same one
// twice it wants to be a component here instead.
//
// The numbers themselves now come from ~/.config/brilliant/tokens.json, read
// live through the `Tokens` singleton. This file has become the ROLE layer —
// which token a given panel part uses, and why — while tokens.json is the
// VALUE layer. Change a number there and every surface that reads it here
// moves at once, with no reload.

import QtQuick
import Quickshell
import qs.CustomTheme

QtObject {
    id: style

    // --- HELPERS ---

    // Qt.alpha() exists but reads badly inline and is easy to mistake for a
    // multiply. Named so a call site says what it means.
    function withAlpha(c: color, a: real): color {
        return Qt.rgba(c.r, c.g, c.b, a)
    }

    // --- THE CARD ---
    //
    // One translucent rectangle with a hairline accent border, sitting on a
    // fully transparent margin that exists purely so the drop shadow has
    // somewhere to fall. That transparent margin is load-bearing beyond the
    // shadow: the Hyprland layer rule that frosts these surfaces
    // (`quickshell-frosted-glass` in ~/.config/hypr/shehan/theming.lua) carries
    // `ignore_alpha = 0.2`, which is what stops it blurring a rectangle of
    // wallpaper around every popup. Keep panelAlpha above that threshold or the
    // frost silently stops applying.

    readonly property int panelRadius: Tokens.radius.lg
    readonly property real panelAlpha: Tokens.opacity.panel
    readonly property color panelColor: style.withAlpha(Theme.background, style.panelAlpha)

    readonly property int panelBorderWidth: Tokens.size.border
    readonly property real panelBorderAlpha: Tokens.opacity.panelBorder
    readonly property color panelBorderColor: style.withAlpha(Theme.primary, style.panelBorderAlpha)

    // Inside the card: how far the content sits off the border, and how far
    // apart consecutive blocks sit.
    readonly property int panelPadding: Tokens.space.huge
    readonly property int panelSpacing: Tokens.space.lg

    // Outside the card: the transparent gutter the shadow lives in. A full
    // panel wants the roomy version; a popout hanging a few pixels off a bar
    // button wants the tight one, or the gap to the bar reads as a mistake.
    readonly property int shadowMargin: Tokens.shadow.margin
    readonly property int popoutShadowMargin: Tokens.shadow.popoutMargin
    readonly property real shadowBlur: Tokens.shadow.blur
    readonly property color shadowColor: style.withAlpha(Theme.shadow, Tokens.opacity.shadow)

    // --- BAR SURFACES ---
    //
    // Two roles, not one, and the distinction is real rather than a place to
    // hide the old drift. A PANEL floats: it is its own object, it casts a
    // shadow, and it is read as sitting in front of the desktop. A BAR SURFACE
    // is glued to the bar — a hover preview, the quicklinks drawer, the player
    // picker — and has to read as part of it, which means matching the bar's
    // own wash rather than a card's.
    //
    // `barAlpha` IS the bar's background. `barPlateAlpha` is something drawn on
    // top of the bar, a little more opaque so it separates from the wash
    // underneath it instead of compositing into a single murkier layer.
    //
    // Radius is BarButton's pill radius deliberately: a plate on the bar that
    // rounds differently from the pills beside it invents a second shape
    // language two centimetres from the first.
    readonly property real barAlpha: Tokens.opacity.bar
    readonly property color barColor: style.withAlpha(Theme.background, style.barAlpha)
    readonly property real barPlateAlpha: Tokens.opacity.barPlate
    readonly property color barPlateColor: style.withAlpha(Theme.background, style.barPlateAlpha)
    readonly property int barRadius: Tokens.radius.md
    readonly property color barBorderColor: style.withAlpha(Theme.primary, Tokens.opacity.barBorder)

    // --- FILLS ---
    //
    // The four states every interactive surface on a panel moves between. They
    // are alphas of on_surface and primary rather than fixed colours so they
    // stay correct through a wallpaper change.

    // A resting plate: tiles, pills, inactive rows.
    readonly property color fillSubtle: style.withAlpha(Theme.on_surface, Tokens.opacity.fillSubtle)
    // Slightly stronger, for a plate that has to read against another plate.
    readonly property color fillRaised: style.withAlpha(Theme.on_surface, Tokens.opacity.fillRaised)
    // The unfilled part of any slider or progress track.
    readonly property color fillTrack: style.withAlpha(Theme.on_surface, Tokens.opacity.fillTrack)
    // Pointer is over it, but it is not on.
    readonly property color fillHover: style.withAlpha(Theme.primary, Tokens.opacity.fillHover)
    // On. Solid accent — this is what makes a toggle readable without a label.
    readonly property color fillActive: Theme.primary
    // Selected-but-not-pressed rows in a list.
    readonly property color fillSelected: style.withAlpha(Theme.primary, Tokens.opacity.fillSelected)

    // A hairline rule between blocks. Faint primary rather than grey, which is
    // what keeps a stack of sections from looking like a spreadsheet.
    readonly property color separatorColor: style.withAlpha(Theme.primary, Tokens.opacity.separator)
    readonly property int separatorHeight: Tokens.size.separator

    // --- TEXT ---
    //
    // Three roles and nothing else. `textOn` is what goes on top of
    // `fillActive` and is the one that is easy to get wrong: on this palette
    // Theme.primary is LIGHT, so light text on an active tile disappears.

    readonly property string fontFamily: Theme.fontFamily
    readonly property color textPrimary: Theme.on_surface
    readonly property color textMuted: Theme.outline
    readonly property color textAccent: Theme.primary
    readonly property color textOn: Theme.on_primary
    readonly property color textError: Theme.error

    // A dimmer shade of the primary text, for a value's trailing clause. Not
    // `textMuted` — outline is a different hue and reads as a different kind of
    // thing (a caption, not a quieter version of the same sentence).
    readonly property color textDim: style.withAlpha(Theme.on_surface, Tokens.opacity.textDim)

    // Sizes. Named by role, because "12" tells the next reader nothing about
    // whether their new label should be 11 or 12.
    readonly property int fsHero: Tokens.font.hero       // the one big number on a panel
    readonly property int fsTitle: Tokens.font.title      // a panel's own title
    readonly property int fsBody: Tokens.font.body       // ordinary rows
    readonly property int fsCaption: Tokens.font.caption    // secondary lines, section headers
    readonly property int fsSmall: Tokens.font.small      // tile labels, notes under a row
    readonly property int fsMicro: Tokens.font.micro       // the caption under a pill's value

    // Section headers: uppercase, tracked out, muted. Consumers read these
    // rather than restating the three properties.
    readonly property int sectionLabelSize: style.fsCaption
    readonly property real sectionLetterSpacing: Tokens.font.sectionLetterSpacing

    // --- ICONS ---
    //
    // Two families, deliberately. Material Icons Round is the panel vocabulary
    // (it has the UI verbs — settings, chevron_right, expand_more). Font Awesome
    // is what the BAR uses, and the bar's own popouts keep it so a glyph in a
    // popout is the same picture as the glyph on the button that opened it.
    //
    // FONT AWESOME NEEDS WEIGHT 900. The four glyphs this desktop leans on
    // (U+F6A9, U+F796, U+F5E7, U+F590) exist only in the Solid-900 face, and
    // fontconfig fallback resolves the family to Regular-400, which renders
    // them as tofu. See BarButton.qml in hyprbar for the long version.
    readonly property string iconFamily: "Material Icons Round"
    readonly property string faFamily: "Font Awesome 7 Free"
    readonly property int faWeight: 900
    readonly property int iconSize: Tokens.size.icon

    // --- CONTROLS ---

    readonly property int controlRadius: Tokens.radius.md
    readonly property int chipRadius: Tokens.radius.xl
    readonly property int buttonRadius: Tokens.radius.sm
    readonly property int buttonHeight: Tokens.size.button
    readonly property int tileHeight: Tokens.size.tile
    readonly property int pillHeight: Tokens.size.pill

    readonly property int trackHeight: Tokens.size.track
    readonly property int trackRadius: Tokens.radius.xs
    readonly property int handleSize: Tokens.size.handle
    // A held handle inverts: accent ring, card-coloured centre. Reads as
    // "picked up" without needing a size change that would shift the track.
    readonly property color handlePressed: Theme.background

    readonly property int switchWidth: Tokens.size.switchWidth
    readonly property int switchHeight: Tokens.size.switchHeight
    readonly property int switchKnob: Tokens.size.switchKnob

    // --- MOTION ---
    //
    // Three speeds. Anything slower than `slow` on a panel that opens and
    // closes as often as these do is felt as lag rather than seen as polish.
    readonly property int animFast: Tokens.motion.duration.fast     // hover recolours
    readonly property int animNormal: Tokens.motion.duration.normal   // state changes, switches
    readonly property int animSlow: Tokens.motion.duration.slow     // a value physically moving
}
