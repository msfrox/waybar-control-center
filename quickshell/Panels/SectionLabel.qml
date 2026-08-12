// The uppercase, tracked-out, muted heading above a group of rows.
//
// Section already contains one of these. Use this directly only where the
// heading is wanted without Section's divider or collapse affordance.

import QtQuick
import QtQuick.Layouts
import qs.Panels

Text {
    Layout.fillWidth: true
    font.family: PanelStyle.fontFamily
    font.pixelSize: PanelStyle.sectionLabelSize
    font.capitalization: Font.AllUppercase
    font.letterSpacing: PanelStyle.sectionLetterSpacing
    color: PanelStyle.textMuted
}
