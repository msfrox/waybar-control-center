// The chrome every panel and popout on this desktop is drawn on: a drop shadow,
// a translucent rounded card, and a padded column to put things in.
//
//     PanelCard {
//         anchors.fill: parent          // full-screen panel
//         Section { ... }
//     }
//
//     PanelCard {                        // a popout, sized by its content
//         shadowMargin: PanelStyle.popoutShadowMargin
//         Section { ... }
//     }
//
// Children go straight in — the default property is the inner ColumnLayout's
// data, so `Layout.fillWidth: true` on a child does what it looks like it does.
//
// WHY THE SHADOW SITS IN A TRANSPARENT MARGIN rather than being a layer effect
// on the card: Hyprland's frosted-glass layer rule matches on alpha, and a
// blur pass over a shadow drawn as part of the surface frosts a rectangle of
// wallpaper the size of the blur radius. Keeping the shadow inside a gutter the
// rule's `ignore_alpha` threshold treats as empty is what stops that.
//
// WHY ONE RECTANGLE and not a gradient: a gradient is a FILL, not a border, so
// it paints the whole card — and then the "translucent" fill above it
// composites against the gradient rather than against the wallpaper, and the
// card is never actually see-through. Learned once in ControlCenterWindow, and
// the comment is repeated here because this is the file that would tempt the
// next person to try it again.

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.Panels

Item {
    id: card

    // The transparent gutter the shadow falls into. Full panels want the roomy
    // default; something hanging off a bar button wants popoutShadowMargin, or
    // the gap between button and card reads as a misalignment.
    property int shadowMargin: PanelStyle.shadowMargin
    // Distance from the card's border to its content.
    property int padding: PanelStyle.panelPadding
    // Gap between consecutive children.
    property alias spacing: column.spacing

    // Off: the card is exactly as tall as its content, which is what a popout
    // wants. On: the content column stretches, which is what a panel with a
    // ScrollView or a spacer in it wants.
    property bool fillHeight: false

    default property alias content: column.data

    // Exposed for the rare consumer that needs to anchor something to the card
    // itself rather than to the content column — a close button in a corner,
    // say. Not for restyling: change PanelStyle instead.
    readonly property alias surface: bg

    implicitWidth: column.implicitWidth + card.padding * 2 + card.shadowMargin * 2
    implicitHeight: column.implicitHeight + card.padding * 2 + card.shadowMargin * 2

    RectangularShadow {
        anchors.fill: bg
        radius: bg.radius
        blur: PanelStyle.shadowBlur
        color: PanelStyle.shadowColor
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        anchors.margins: card.shadowMargin
        radius: PanelStyle.panelRadius
        color: PanelStyle.panelColor
        border.width: PanelStyle.panelBorderWidth
        border.color: PanelStyle.panelBorderColor
    }

    ColumnLayout {
        id: column
        anchors.left: bg.left
        anchors.right: bg.right
        anchors.top: bg.top
        // Only when asked. Anchoring the bottom unconditionally would stretch a
        // content-sized popout's last child to fill a height that is itself
        // derived from that child.
        anchors.bottom: card.fillHeight ? bg.bottom : undefined
        anchors.margins: card.padding
        spacing: PanelStyle.panelSpacing
    }
}
