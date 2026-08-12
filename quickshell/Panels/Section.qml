// A titled block of rows: heading, content, divider.
//
//     Section {
//         title: "POWER PROFILE"
//         glyph: "bolt"
//         StatRow { ... }
//     }
//
// This is the unit a panel is assembled from. Anything dropped inside inherits
// the block's spacing, its divider and — if the consumer asks for it — its
// collapse behaviour, so a new group of rows is one component and no layout
// decisions.
//
// COLLAPSING has two modes, and picking the wrong one is the bug this
// component is shaped to prevent. `selfManaged` (the default) means the header
// toggles `collapsed` directly, which is right for a popout where the state
// dies with the window. A panel that PERSISTS the collapse state must set
// `selfManaged: false` and bind `collapsed` to its own store: assigning to a
// bound property destroys the binding, so a self-managed section whose owner
// also binds `collapsed` would ignore every later reload of that store.

import QtQuick
import QtQuick.Layouts
import qs.Panels

ColumnLayout {
    id: section

    required property string title
    property string glyph: ""

    // Whether the header responds to a click at all. Off by default: a popout
    // that reopens from scratch every time gains nothing from a control whose
    // effect it immediately forgets.
    property bool collapsible: false
    property bool collapsed: false
    // See the header comment. Off means "the owner owns `collapsed`".
    property bool selfManaged: true

    // Emitted on every header click, whether or not this section manages its
    // own state. An owner with a persisted store listens to this.
    signal toggleRequested

    // The rule under the block. Off for the last section on a card, where it
    // draws a line above nothing.
    property bool showDivider: true

    default property alias content: holder.data

    Layout.fillWidth: true
    spacing: 6

    // The header is wrapped in a plain Item so the click target can use
    // anchors: a MouseArea placed directly in a Layout is layout-managed, and
    // anchoring a layout-managed item is undefined behaviour Qt warns about.
    Item {
        Layout.fillWidth: true
        implicitHeight: 24

        RowLayout {
            anchors.fill: parent
            spacing: 8

            Glyph {
                text: section.glyph
                font.pixelSize: PanelStyle.fsTitle
                visible: section.glyph !== ""
            }

            SectionLabel {
                text: section.title
            }

            Glyph {
                visible: section.collapsible
                text: section.collapsed ? "expand_more" : "expand_less"
                font.pixelSize: 18
                color: PanelStyle.textMuted
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: section.collapsible
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                section.toggleRequested()
                if (section.selfManaged)
                    section.collapsed = !section.collapsed
            }
        }
    }

    ColumnLayout {
        id: holder
        Layout.fillWidth: true
        spacing: 6
        visible: !section.collapsed
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 4
        visible: section.showDivider
        implicitHeight: PanelStyle.separatorHeight
        color: PanelStyle.separatorColor
    }
}
