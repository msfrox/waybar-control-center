// A small glyph-and-label button, sized to share a row with its siblings.
//
//     RowLayout {
//         ActionButton { glyph: ""; label: "Lock";  onTriggered: ... }
//         ActionButton { glyph: ""; label: "Sleep"; onTriggered: ... }
//     }
//
// `destructive` swaps the hover tint to the error colour. It is the affordance
// that separates "Sleep" from "Shut down" at a glance without a confirmation
// dialog on every one of them.

import QtQuick
import QtQuick.Layouts
import qs.Panels

Rectangle {
    id: actionBtn

    property string glyph: ""
    property string label: ""
    property bool destructive: false

    signal triggered

    Layout.fillWidth: true
    Layout.preferredHeight: PanelStyle.buttonHeight
    radius: PanelStyle.buttonRadius
    color: !actionMouse.containsMouse
           ? PanelStyle.fillRaised
           : (actionBtn.destructive
              ? PanelStyle.withAlpha(PanelStyle.textError, 0.22)
              : PanelStyle.withAlpha(PanelStyle.textAccent, 0.22))
    Behavior on color { ColorAnimation { duration: PanelStyle.animFast } }

    RowLayout {
        anchors.centerIn: parent
        spacing: 6

        FaGlyph {
            text: actionBtn.glyph
            color: actionBtn.destructive && actionMouse.containsMouse
                   ? PanelStyle.textError : PanelStyle.textPrimary
        }

        Text {
            text: actionBtn.label
            font.family: PanelStyle.fontFamily
            font.pixelSize: PanelStyle.fsCaption
            font.bold: true
            color: actionBtn.destructive && actionMouse.containsMouse
                   ? PanelStyle.textError : PanelStyle.textPrimary
        }
    }

    MouseArea {
        id: actionMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: actionBtn.triggered()
    }
}
