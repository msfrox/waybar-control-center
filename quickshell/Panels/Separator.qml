// A hairline rule between blocks inside a card.
//
// Faint primary rather than a grey line: on a translucent card a neutral rule
// reads as a table border, and a stack of them makes a panel look like a
// spreadsheet. Section already draws one of these under itself, so this is for
// the places that group rows WITHOUT a heading.

import QtQuick
import QtQuick.Layouts
import qs.Panels

Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: PanelStyle.separatorHeight
    color: PanelStyle.separatorColor
}
