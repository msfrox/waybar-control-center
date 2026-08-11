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
    // Bare modules hover by RECOLOURING to @primary, not by showing a plate — that
    // is what the Waybar sheet does and it is the difference between the cutover
    // being invisible and the bar feeling subtly wrong. Pills are the ones that
    // change their fill.
    property color contentColor: btn.pill
        ? Theme.on_secondary
        : (mouse.containsMouse || btn.active ? Theme.primary : Theme.on_surface)

    property int glyphSize: 20
    property int labelSize: 13
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
    // Pills do not fill the bar's full height — the Waybar CSS insets them 3px top
    // and bottom. Bare modules do fill it, so their hover plate covers the strip.
    implicitHeight: parent ? parent.height - (pill ? 6 : 0) : 32
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

        Text {
            visible: btn.label !== ""
            text: btn.label
            font.family: Theme.fontFamily
            font.pixelSize: btn.labelSize
            color: btn.contentColor
            verticalAlignment: Text.AlignVCenter
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
