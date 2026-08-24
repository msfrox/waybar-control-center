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
//
// SETTINGS-OVERRIDE MARKERS, added in the 2.2 sweep. Every property below
// carries a trailing `// settings: tokens.<group>.<key>` comment naming the
// exact tokens.json path it reads through `Tokens`. This is the one place
// Phase 3's settings sweep should grep to build the appearance/motion pages —
// point a control at the named key rather than re-deriving which of these
// ~40 roles maps to which JSON field. A role with no matching comment reads
// straight off `Theme` (colour, not a token) and is out of scope for that page.

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

    readonly property int panelRadius: Tokens.radius.lg              // settings: tokens.radius.lg
    readonly property real panelAlpha: Tokens.opacity.panel          // settings: tokens.opacity.panel
    readonly property color panelColor: style.withAlpha(Theme.background, style.panelAlpha)

    readonly property int panelBorderWidth: Tokens.size.border       // settings: tokens.size.border
    readonly property real panelBorderAlpha: Tokens.opacity.panelBorder  // settings: tokens.opacity.panelBorder
    readonly property color panelBorderColor: style.withAlpha(Theme.primary, style.panelBorderAlpha)

    // Inside the card: how far the content sits off the border, and how far
    // apart consecutive blocks sit.
    readonly property int panelPadding: Tokens.space.huge            // settings: tokens.space.huge
    readonly property int panelSpacing: Tokens.space.lg              // settings: tokens.space.lg

    // Outside the card: the transparent gutter the shadow lives in. A full
    // panel wants the roomy version; a popout hanging a few pixels off a bar
    // button wants the tight one, or the gap to the bar reads as a mistake.
    readonly property int shadowMargin: Tokens.shadow.margin         // settings: tokens.shadow.margin
    readonly property int popoutShadowMargin: Tokens.shadow.popoutMargin  // settings: tokens.shadow.popoutMargin
    readonly property real shadowBlur: Tokens.shadow.blur            // settings: tokens.shadow.blur
    readonly property color shadowColor: style.withAlpha(Theme.shadow, Tokens.opacity.shadow)  // settings: tokens.opacity.shadow

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
    readonly property real barAlpha: Tokens.opacity.bar              // settings: tokens.opacity.bar
    readonly property color barColor: style.withAlpha(Theme.background, style.barAlpha)
    readonly property real barPlateAlpha: Tokens.opacity.barPlate    // settings: tokens.opacity.barPlate
    readonly property color barPlateColor: style.withAlpha(Theme.background, style.barPlateAlpha)
    readonly property int barRadius: Tokens.radius.md                // settings: tokens.radius.md
    readonly property color barBorderColor: style.withAlpha(Theme.primary, Tokens.opacity.barBorder)  // settings: tokens.opacity.barBorder

    // --- FILLS ---
    //
    // The four states every interactive surface on a panel moves between. They
    // are alphas of on_surface and primary rather than fixed colours so they
    // stay correct through a wallpaper change.
    //
    // UNIFIED in the 2.2 sweep: every popup's device/tray/list row now reads
    // its hover-only state from `fillHover` and its selected/pressed/on state
    // from `fillSelected` — a handful of surfaces had drifted onto raw 0.12 /
    // 0.14 literals for what was semantically the same two states. Route new
    // interactive rows through these two rather than inventing a third.

    // A resting plate: tiles, pills, inactive rows.
    readonly property color fillSubtle: style.withAlpha(Theme.on_surface, Tokens.opacity.fillSubtle)  // settings: tokens.opacity.fillSubtle
    // Slightly stronger, for a plate that has to read against another plate.
    readonly property color fillRaised: style.withAlpha(Theme.on_surface, Tokens.opacity.fillRaised)  // settings: tokens.opacity.fillRaised
    // The unfilled part of any slider or progress track.
    readonly property color fillTrack: style.withAlpha(Theme.on_surface, Tokens.opacity.fillTrack)   // settings: tokens.opacity.fillTrack
    // Pointer is over it, but it is not on. THE canonical hover-only fill —
    // every device row / tray row / list row hover across every popup.
    readonly property color fillHover: style.withAlpha(Theme.primary, Tokens.opacity.fillHover)      // settings: tokens.opacity.fillHover
    // On. Solid accent — this is what makes a toggle readable without a label.
    readonly property color fillActive: Theme.primary
    // Selected-but-not-pressed rows in a list. THE canonical selected/pressed
    // fill — every chip/tile "on" state across every popup.
    readonly property color fillSelected: style.withAlpha(Theme.primary, Tokens.opacity.fillSelected)  // settings: tokens.opacity.fillSelected

    // A hairline rule between blocks. Faint primary rather than grey, which is
    // what keeps a stack of sections from looking like a spreadsheet.
    readonly property color separatorColor: style.withAlpha(Theme.primary, Tokens.opacity.separator)  // settings: tokens.opacity.separator
    readonly property int separatorHeight: Tokens.size.separator     // settings: tokens.size.separator
    // A Divider component's own opacity (distinct from separatorColor, which
    // is a primary-tinted rule; a Divider is a plain on_surface hairline at a
    // slightly stronger alpha). Added in the 2.2 sweep to close a real gap —
    // every popup's Divider had independently landed on the same 0.3 with
    // nothing in the scale to snap to.
    readonly property real dividerAlpha: Tokens.opacity.divider      // settings: tokens.opacity.divider

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
    readonly property color textDim: style.withAlpha(Theme.on_surface, Tokens.opacity.textDim)  // settings: tokens.opacity.textDim

    // Sizes. Named by role, because "12" tells the next reader nothing about
    // whether their new label should be 11 or 12.
    readonly property int fsHero: Tokens.font.hero       // settings: tokens.font.hero — the one big number on a panel
    readonly property int fsTitle: Tokens.font.title      // settings: tokens.font.title — a panel's own title
    readonly property int fsBody: Tokens.font.body       // settings: tokens.font.body — ordinary rows
    readonly property int fsCaption: Tokens.font.caption    // settings: tokens.font.caption — secondary lines, section headers
    readonly property int fsSmall: Tokens.font.small      // settings: tokens.font.small — tile labels, notes under a row
    readonly property int fsMicro: Tokens.font.micro       // settings: tokens.font.micro — the caption under a pill's value

    // Section headers: uppercase, tracked out, muted. Consumers read these
    // rather than restating the three properties.
    readonly property int sectionLabelSize: style.fsCaption
    readonly property real sectionLetterSpacing: Tokens.font.sectionLetterSpacing  // settings: tokens.font.sectionLetterSpacing

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
    readonly property int iconSize: Tokens.size.icon      // settings: tokens.size.icon

    // --- CONTROLS ---

    readonly property int controlRadius: Tokens.radius.md  // settings: tokens.radius.md
    readonly property int chipRadius: Tokens.radius.xl      // settings: tokens.radius.xl
    readonly property int buttonRadius: Tokens.radius.sm    // settings: tokens.radius.sm
    readonly property int buttonHeight: Tokens.size.button  // settings: tokens.size.button
    readonly property int tileHeight: Tokens.size.tile      // settings: tokens.size.tile
    readonly property int pillHeight: Tokens.size.pill      // settings: tokens.size.pill

    readonly property int trackHeight: Tokens.size.track    // settings: tokens.size.track
    readonly property int trackRadius: Tokens.radius.xs     // settings: tokens.radius.xs
    readonly property int handleSize: Tokens.size.handle    // settings: tokens.size.handle
    // A held handle inverts: accent ring, card-coloured centre. Reads as
    // "picked up" without needing a size change that would shift the track.
    readonly property color handlePressed: Theme.background

    readonly property int switchWidth: Tokens.size.switchWidth    // settings: tokens.size.switchWidth
    readonly property int switchHeight: Tokens.size.switchHeight  // settings: tokens.size.switchHeight
    readonly property int switchKnob: Tokens.size.switchKnob      // settings: tokens.size.switchKnob

    // --- MOTION ---
    //
    // Three speeds. Anything slower than `slow` on a panel that opens and
    // closes as often as these do is felt as lag rather than seen as polish.
    // UNIFIED in the 2.2 sweep: every popup's open/close slide now reads
    // `Tokens.motion.duration.slower` directly (no role existed for it here
    // before this pass) rather than each window carrying its own 350 literal.
    readonly property int animFast: Tokens.motion.duration.fast     // settings: tokens.motion.duration.fast — hover recolours
    readonly property int animNormal: Tokens.motion.duration.normal   // settings: tokens.motion.duration.normal — state changes, switches
    readonly property int animSlow: Tokens.motion.duration.slow     // settings: tokens.motion.duration.slow — a value physically moving
    readonly property int animSlower: Tokens.motion.duration.slower  // settings: tokens.motion.duration.slower — a whole panel sliding open/closed
}
