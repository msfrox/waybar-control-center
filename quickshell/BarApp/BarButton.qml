// One module on the bar: an optional Material Icons glyph, an optional text label,
// and the three mouse buttons Waybar modules bind (`on-click`, `on-click-right`,
// `on-click-middle`) plus scroll.
//
// Deliberately not a Controls `Button`. Two reasons, both learned the hard way and
// both recorded in HANDOFF.md: a Controls Button propagates its own font onto
// `contentItem`, so a Material Icons ligature renders as the literal word "dashboard";
// and `highlighted` is FINAL on it, so shadowing it fails the whole Quickshell config
// to load with an error that points at the property rather than the cause.
//
// COLOURS come from `Theme`, i.e. Matugen, i.e. the wallpaper — but the mapping is not
// one-to-one with the Waybar CSS names, and copying those across literally gets it
// wrong. `ml4w-modern/colored/style.css` remaps four of them before importing the
// shared sheet:
//
//     on_surface -> on_secondary      background -> secondary
//     icon_color -> on_secondary      border_color -> secondary
//
// So `#clock { background: @background; color: @on_surface }` is really "secondary
// fill, on_secondary text" — a LIGHT pill with dark text, not the dark-on-dark that
// the names suggest. Those resolved values are what the pill properties below use.
//
// Bare modules are the other half of the same trap: they sit transparent on the bar,
// where a near-black @on_surface would vanish, which is why the Waybar sheet gives
// them @bar_fg (pinned light) instead. Theme.on_surface here is the genuine Matugen
// value rather than the variant's override, so it is already light in dark mode and
// needs no equivalent pin.

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.CustomTheme

Rectangle {
    id: btn

    // A Material Icons Round ligature name ("dashboard", "apps"), or a literal
    // glyph from the icon font the bar already uses.
    property string glyph: ""
    property string label: ""
    // For modules whose "icon" is an asset rather than a glyph. Waybar does these
    // as a CSS background-image on a module whose format is a single space, which
    // is invisible as config — #custom-ml4w-welcome is one.
    property url iconSource: ""
    property int iconSize: 20

    // Waybar's two module shapes. Bare (the default) is a transparent module that
    // only shows a plate on hover; a pill is opaque with a 2px border, which on this
    // theme is #clock, #backlight and friends. Keeping both means the cutover does
    // not quietly restyle half the bar.
    property bool pill: false
    property int minWidth: 0
    // Waybar spaces modules with per-module CSS margins rather than a uniform gap,
    // and the values differ (13px after the Control Center, 12px after the ML4W
    // logo). Carried across per module so the right group's rhythm survives.
    property int rightMargin: 0
    Layout.rightMargin: btn.rightMargin

    // Set by modules that want to signal state rather than just sit there —
    // a muted volume, a disconnected network, an active toggle.
    property bool active: false
    // Exposed because a module that overrides `contentColor` to show state — muted
    // audio, a disconnected network, a critical battery — still has to fold the hover
    // recolour back in, and a derived component cannot see the MouseArea's id.
    readonly property alias hovered: mouse.containsMouse
    // Bare modules hover by RECOLOURING to @primary, not by showing a plate — that
    // is what the Waybar sheet does and it is the difference between the cutover
    // being invisible and the bar feeling subtly wrong. Pills are the ones that
    // change their fill.
    property color contentColor: btn.pill
        ? Theme.on_secondary
        : (mouse.containsMouse || btn.active ? Theme.primary : Theme.on_surface)

    property int glyphSize: 20
    property int labelSize: 13
    // ICON RUNS INSIDE THE LABEL.
    //
    // Waybar renders each status module as ONE GTK label whose format string mixes
    // text with Font Awesome codepoints in the Unicode private use area, and its CSS
    // font-family is a CHAIN that resolves each character to whichever family has it.
    // Neither of Qt's two obvious equivalents works here:
    //
    //   * `font.families` is rejected outright by Quickshell 0.3.0 ("Cannot assign to
    //     non-existent property"), even though plain Qt 6.11 accepts it.
    //   * Automatic fontconfig fallback is not a substitute. Four of the glyphs this
    //     bar needs - U+F6A9 muted, U+F796 network-wired, U+F5E7 charging bolt and
    //     U+F590 headset - exist in exactly ONE installed font, Font Awesome 7 Free,
    //     and the only file behind that family name is its Solid-900 face. Fallback
    //     resolves the family to a Regular-400 face that genuinely lacks them, so they
    //     render as tofu. StyledText's `<font face=...>` fails identically, because a
    //     face attribute cannot carry a weight.
    //
    // Asking for weight 900 explicitly is what fixes it. So the label is split into
    // runs here: private-use characters render in the icon family at 900, everything
    // else in the UI font. Keeping that inside BarButton means each module still sets
    // one `label` to Waybar's format string verbatim - including the ones that put an
    // icon AFTER the text (pulseaudio's format-bluetooth) or use two icons at once.
    property string iconFamily: "Font Awesome 7 Free"
    property int iconWeight: 900

    // `label` as alternating text / icon runs, in order.
    function labelRuns(s: string): var {
        let out = [], cur = "", curIcon = false
        for (let i = 0; i < s.length; i++) {
            const c = s.charCodeAt(i)
            // The private use area. Font Awesome, Nerd Fonts and Material Icons all
            // live in here; ordinary text does not, and neither do the stray symbols
            // these format strings use (U+2713 check, U+26A0 warning) - those stay in
            // the UI font and reach a symbol font through ordinary fallback.
            const isIcon = c >= 0xe000 && c <= 0xf8ff
            if (cur !== "" && isIcon !== curIcon) {
                out.push({ icon: curIcon, text: cur })
                cur = ""
            }
            curIcon = isIcon
            cur += s[i]
        }
        if (cur !== "") out.push({ icon: curIcon, text: cur })
        return out
    }
    // Zero, because Waybar's bare modules are `padding: 0px` and space themselves
    // with margins alone. Pills override it (#clock is `padding: 1px 10px`).
    // Anything non-zero here shows up as the bar reading looser than the one it
    // replaced, which is the kind of drift a cutover is supposed to avoid.
    property int hpadding: 0

    signal clicked
    signal rightClicked
    signal middleClicked
    // Positive is scroll up / right, matching Waybar's smooth-scrolling sense.
    signal scrolled(int delta)

    implicitWidth: Math.max(minWidth, row.implicitWidth + hpadding * 2)

    // GTK sizes a pill from its CONTENT and never stretches it to the bar, so the
    // height is a constant, not a function of `parent.height`. Measured off the live
    // Waybar: every pill on it — #clock, #workspaces button — is 34.7px tall inside a
    // 52px bar, leaving an 8.7px gap above and below. Deriving it from the bar
    // instead (the old `parent.height - 6`) gave 46px pills that visibly touched the
    // bar's edges, which is the single most obvious "this isn't Waybar" tell.
    //
    // Bare modules are not pills and do follow the bar, but the sheet still insets
    // them 6px top and bottom (`margin: 6px 0px 6px 0px`). They draw no plate, so
    // that only sets the click target — which is still worth matching.
    property int pillHeight: 35
    implicitHeight: pill ? pillHeight : (parent ? parent.height - 12 : 32)
    // Layout.alignment, not anchors: every module sits in one of the bar's three
    // RowLayouts, and anchoring an item a layout manages is undefined behaviour
    // (Qt warns, then does something arbitrary with the height).
    Layout.alignment: Qt.AlignVCenter

    radius: 8

    // Bare: a hover plate only. The bar is translucent and every permanent
    // background on it is one more thing competing with the wallpaper.
    // Pill: opaque, bordered, and recoloured on hover rather than plated.
    // Pill fill is @background, which the variant remaps to @secondary; on hover the
    // shared sheet switches it to @primary_container and the border to @primary.
    // Bare modules stay transparent at all times — their hover lives in contentColor.
    color: pill ? (mouse.containsMouse ? Theme.primary_container : Theme.secondary)
                : "transparent"

    border.width: pill ? 2 : 0
    border.color: pill && mouse.containsMouse ? Theme.primary : Theme.secondary

    Behavior on color {
        ColorAnimation { duration: 120 }
    }
    Behavior on border.color {
        ColorAnimation { duration: 120 }
    }

    RowLayout {
        id: row
        anchors.centerIn: parent

        // The `text-shadow: 0 1px 3px rgba(0,0,0,0.85)` the Waybar sheet puts on every
        // bare module, so a light glyph stays readable where the translucent bar lets
        // a bright wallpaper through. Pills have an opaque fill and do not need it.
        layer.enabled: !btn.pill
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.85)
            shadowVerticalOffset: 1
            shadowBlur: 0.4
        }
        spacing: btn.label !== "" && (btn.glyph !== "" || String(btn.iconSource) !== "")
                 ? 6 : 0

        Image {
            visible: String(btn.iconSource) !== ""
            source: btn.iconSource
            // SVG: render at the target size rather than scaling a default-size
            // raster, or the logo comes out soft.
            sourceSize.width: btn.iconSize
            sourceSize.height: btn.iconSize
            Layout.preferredWidth: btn.iconSize
            Layout.preferredHeight: btn.iconSize
            fillMode: Image.PreserveAspectFit
        }

        Text {
            visible: btn.glyph !== ""
            text: btn.glyph
            font.family: "Material Icons Round"
            font.pixelSize: btn.glyphSize
            color: btn.contentColor
            verticalAlignment: Text.AlignVCenter
        }

        // One Text per run, laid out edge to edge so they read as the single label
        // Waybar draws. The RowLayout's own spacing would open a gap between an icon
        // and the text beside it, so the runs get their own zero-spacing Row.
        Row {
            spacing: 0
            Layout.alignment: Qt.AlignVCenter

            Repeater {
                model: btn.labelRuns(btn.label)

                delegate: Text {
                    required property var modelData
                    text: modelData.text
                    font.family: modelData.icon ? btn.iconFamily : Theme.fontFamily
                    // DemiBold, not Normal, for the text runs. "Fira Sans Semibold"
                    // names a STYLE inside the Fira Sans family, so asking for it by
                    // family name alone and then pinning weight 400 gets the Regular
                    // face — which measured 12px narrower than the same string on
                    // Waybar. 600 is what Semibold means.
                    font.weight: modelData.icon ? btn.iconWeight : Font.DemiBold
                    font.pixelSize: btn.labelSize
                    color: btn.contentColor
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: (event) => {
            if (event.button === Qt.LeftButton) btn.clicked()
            else if (event.button === Qt.RightButton) btn.rightClicked()
            else if (event.button === Qt.MiddleButton) btn.middleClicked()
        }

        // angleDelta is in eighths of a degree; one notch is 120. Modules that care
        // about a threshold (the workspace switcher does) count notches themselves.
        onWheel: (event) => {
            const notches = event.angleDelta.y !== 0 ? event.angleDelta.y / 120
                                                     : event.angleDelta.x / 120
            if (notches !== 0) btn.scrolled(notches)
        }
    }
}
