// One line of read-only information: marker, what it is, what it says.
//
//     StatRow { glyph: ""; label: "Charging at"; value: "+31.2 W" }
//
// `note` is the trailing clause that gives a bare number its units or its
// provenance — "95%  ·  64.7 of 68.0 Wh". It hangs off the value rather than
// sitting under the label because the thing it qualifies is the value.

import QtQuick
import QtQuick.Layouts
import qs.Panels

RowLayout {
    id: statRow

    // A Font Awesome codepoint, or "" for a row with no marker.
    property string glyph: ""
    property string label: ""
    property string value: ""
    property string note: ""

    Layout.fillWidth: true
    spacing: 8

    FaGlyph {
        text: statRow.glyph
        Layout.preferredWidth: 14
        Layout.alignment: Qt.AlignVCenter
    }

    Text {
        text: statRow.label
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        font.family: PanelStyle.fontFamily
        font.pixelSize: PanelStyle.fsBody
        color: PanelStyle.textPrimary
    }

    Text {
        text: statRow.note !== "" ? statRow.value + "  ·  " + statRow.note
                                  : statRow.value
        Layout.alignment: Qt.AlignVCenter
        font.family: PanelStyle.fontFamily
        font.pixelSize: PanelStyle.fsBody
        font.bold: true
        color: PanelStyle.textPrimary
    }
}
