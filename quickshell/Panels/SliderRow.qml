// Marker glyph, slider, readout. Brightness, volume, anything on a 0-100 ramp.
//
//     SliderRow {
//         glyph: ""
//         value: root.brightness
//         onMoved: (v) => root.setBrightness(v)
//     }
//
// THE BINDING TRAP, which cost a debugging session in ControlCenterWindow and
// is fixed here once so no consumer has to know about it: dragging a Controls
// Slider ASSIGNS its `value`, and that destroys the `value: row.value` binding
// for good. Without the Connections block below, the next reading from outside
// (a brightness key, hypridle's idle dim) would land in a property nothing was
// watching and the handle would stay where it was last dragged. The binding is
// re-asserted on every new input — but never while the handle is held, or the
// drag would fight the last poll.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Panels

RowLayout {
    id: row

    // A Font Awesome codepoint, or "" for no marker.
    property string glyph: ""
    property int from: 0
    property int to: 100
    // The current value FROM THE OWNER. Never written here.
    property int value: 0
    property string suffix: "%"
    // Hidden entirely when a bare track is wanted.
    property bool showReadout: true

    signal moved(int value)

    Layout.fillWidth: true
    spacing: 12

    FaGlyph {
        text: row.glyph
        visible: row.glyph !== ""
        font.pixelSize: 13
        color: PanelStyle.withAlpha(PanelStyle.textPrimary, 0.75)
        Layout.alignment: Qt.AlignVCenter
    }

    Slider {
        id: slider
        Layout.fillWidth: true
        from: row.from
        to: row.to
        value: row.value
        onMoved: row.moved(Math.round(value))

        Connections {
            target: row
            function onValueChanged() {
                if (!slider.pressed)
                    slider.value = row.value
            }
        }

        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            implicitHeight: PanelStyle.trackHeight
            width: slider.availableWidth
            height: implicitHeight
            radius: PanelStyle.trackRadius
            color: PanelStyle.fillTrack

            Rectangle {
                width: slider.visualPosition * parent.width
                height: parent.height
                radius: parent.radius
                color: PanelStyle.fillActive
            }
        }

        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            implicitWidth: PanelStyle.handleSize
            implicitHeight: PanelStyle.handleSize
            radius: 100
            color: slider.pressed ? PanelStyle.handlePressed : PanelStyle.fillActive
            border.color: PanelStyle.fillActive
            border.width: 2
        }
    }

    Text {
        // The HANDLE's value, not the owner's. The owner's is only refreshed on
        // a poll, so reading from it leaves the number frozen for the whole drag.
        visible: row.showReadout
        text: Math.round(slider.value) + row.suffix
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: 38
        Layout.alignment: Qt.AlignVCenter
        font.family: PanelStyle.fontFamily
        font.pixelSize: PanelStyle.fsBody
        color: PanelStyle.textPrimary
    }
}
