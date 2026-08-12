// A labelled switch, with an optional explanatory line under the label.
//
//     ToggleRow {
//         glyph: ""
//         label: "Keep awake"
//         note: checked ? "Screen and sleep are blocked" : "Normal idle timers"
//         checked: root.keepAwake
//         onToggled: (v) => root.keepAwakeToggled(v)
//     }
//
// `checked` is an INPUT, never assigned here. The row emits `toggled` and the
// owner decides — which is what lets the state live in a settings file with one
// writer instead of in the widget.
//
// A disabled row dims and stops responding rather than disappearing. Hiding a
// setting that another setting currently overrides makes the overriding toggle
// look like it did nothing; showing it greyed says what will happen when the
// override is lifted.

import QtQuick
import QtQuick.Layouts
import qs.Panels

RowLayout {
    id: toggleRow

    property string glyph: ""
    property string label: ""
    property string note: ""
    property bool checked: false

    signal toggled(bool value)

    Layout.fillWidth: true
    spacing: 8
    opacity: toggleRow.enabled ? 1 : 0.45

    FaGlyph {
        text: toggleRow.glyph
        color: toggleRow.checked ? PanelStyle.textAccent : PanelStyle.textDim
        Layout.preferredWidth: 14
        Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: toggleRow.label
            elide: Text.ElideRight
            font.family: PanelStyle.fontFamily
            font.pixelSize: PanelStyle.fsBody
            color: PanelStyle.textPrimary
        }

        Text {
            Layout.fillWidth: true
            visible: toggleRow.note !== ""
            text: toggleRow.note
            elide: Text.ElideRight
            font.family: PanelStyle.fontFamily
            font.pixelSize: PanelStyle.fsSmall
            color: PanelStyle.textMuted
        }
    }

    Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: PanelStyle.switchWidth
        implicitHeight: PanelStyle.switchHeight
        radius: height / 2
        color: toggleRow.checked ? PanelStyle.fillActive : PanelStyle.fillTrack
        Behavior on color { ColorAnimation { duration: PanelStyle.animNormal } }

        Rectangle {
            width: PanelStyle.switchKnob
            height: PanelStyle.switchKnob
            radius: height / 2
            y: (parent.height - height) / 2
            x: toggleRow.checked ? parent.width - width - y : y
            color: toggleRow.checked ? PanelStyle.textOn : PanelStyle.textPrimary
            Behavior on x {
                NumberAnimation { duration: PanelStyle.animNormal; easing.type: Easing.OutCubic }
            }
            Behavior on color { ColorAnimation { duration: PanelStyle.animNormal } }
        }

        MouseArea {
            anchors.fill: parent
            // Widened past the switch itself. A 34x18 hit box is a miss waiting
            // to happen, and the row has nothing else clickable to steal from.
            anchors.margins: -6
            enabled: toggleRow.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: toggleRow.toggled(!toggleRow.checked)
        }
    }
}
