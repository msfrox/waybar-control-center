import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.CustomTheme
import qs.Panels

// One notification, as drawn in the panel list and inside a toast.
//
// Shared by both so a notification looks the same wherever it appears — the
// toast is this plus its own window and an expiry timer.
Rectangle {
    id: entry

    required property var notification
    // Toasts sit on their own translucent card and want no second background.
    property bool showBackground: true
    // "" (the default, used by the panel list) means "no override" — Toasts
    // pass `NotificationState.font` here, letting the toast surface's font
    // choice (hyprsys' Notifications page) apply without touching how a
    // notification reads in the persistent panel.
    property string fontOverride: ""
    readonly property string effectiveFont: entry.fontOverride !== "" ? entry.fontOverride : Theme.fontFamily

    implicitHeight: layout.implicitHeight + 20
    radius: PanelStyle.controlRadius
    color: showBackground
        ? Qt.rgba(Theme.surface_container_high.r, Theme.surface_container_high.g,
                  Theme.surface_container_high.b, 0.45)
        : "transparent"

    // Critical notifications get a coloured edge rather than a coloured fill —
    // the fill is translucent over the wallpaper and tinting it reads as noise.
    Rectangle {
        visible: entry.notification.urgency === NotificationUrgency.Critical
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        radius: 2
        color: Theme.error
    }

    RowLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Tokens.space.lg
        spacing: Tokens.space.lg

        // --- ICON ---
        // `image` is the picture a notification carries (album art, an avatar);
        // `appIcon` is the sending app's icon. Prefer the former.
        Item {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            visible: img.source !== ""

            IconImage {
                id: img
                anchors.fill: parent
                source: entry.notification.image !== ""
                    ? entry.notification.image
                    : (entry.notification.appIcon !== ""
                        ? Quickshell.iconPath(entry.notification.appIcon, true)
                        : "")
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.space.xxs

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.sm

                Text {
                    text: entry.notification.appName
                    color: Theme.primary
                    opacity: 0.8
                    font.family: entry.effectiveFont
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    Layout.maximumWidth: 160
                }

                Text {
                    text: NotificationState.ageTextFor(entry.notification)
                    visible: text !== ""
                    color: Theme.on_background
                    opacity: 0.45
                    font.family: entry.effectiveFont
                    font.pixelSize: 11
                }

                Item { Layout.fillWidth: true }

                // Close. Deliberately always visible rather than hover-only —
                // this panel is used with a trackpad as often as a mouse.
                //
                // A plain Text rather than a Button: Controls propagates the
                // control's own font down onto its contentItem, which overrides
                // the family and renders the Material Icons ligature as the
                // literal word "close". Same reason AudioWindow's Glyph is a Text.
                Text {
                    text: "close"
                    font.family: "Material Icons Round"
                    font.pixelSize: 16
                    color: Theme.on_background
                    opacity: closeArea.containsMouse ? 0.9 : 0.45
                    verticalAlignment: Text.AlignVCenter

                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: NotificationState.dismiss(entry.notification)
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: entry.notification.summary
                visible: text !== ""
                color: Theme.on_background
                font.family: entry.effectiveFont
                font.pixelSize: 13
                font.bold: true
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: entry.notification.body
                visible: text !== ""
                color: Theme.on_background
                opacity: 0.75
                font.family: entry.effectiveFont
                font.pixelSize: 12
                // The server advertises body markup, so senders may use Pango.
                textFormat: Text.RichText
                wrapMode: Text.WordWrap
                maximumLineCount: 5
                elide: Text.ElideRight
                onLinkActivated: (link) => Quickshell.execDetached(["xdg-open", link])
            }

            // --- ACTIONS ---
            Flow {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.space.sm
                spacing: Tokens.space.sm
                visible: entry.notification.actions.length > 0

                Repeater {
                    model: entry.notification.actions

                    Button {
                        required property var modelData
                        background: Rectangle {
                            color: "transparent"
                            border.color: Theme.primary
                            border.width: 1
                            radius: PanelStyle.buttonRadius
                        }
                        contentItem: Text {
                            text: modelData.text
                            font.family: entry.effectiveFont
                            font.pixelSize: 11
                            color: Theme.primary
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            padding: 3
                            leftPadding: Tokens.space.lg
                            rightPadding: Tokens.space.lg
                        }
                        onClicked: {
                            modelData.invoke()
                            // A resident notification asks to stay after its
                            // action runs; anything else is done with.
                            if (!entry.notification.resident) NotificationState.dropToast(entry.notification)
                        }
                    }
                }
            }
        }
    }
}
