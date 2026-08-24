import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import qs.CustomTheme
import qs.Panels

// The notification centre: clock, calendar, notifications, bottom right.
//
// This replaces ML4W's CalendarApp rather than patching it. The calendar had to
// end up in the same surface as the notification list, and ML4W owns that file —
// anything left depending on it breaks on their next dotfiles update.
//
// Window chrome (layer, slide animation, focus grab, IPC) follows the same shape
// as every other panel in this repo.
PanelWindow {
    id: root

    // --- WAYLAND CONFIGURATION ---
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: WlrLayershell.Ignore

    implicitWidth: 440
    // The card sizes to its contents, so the window has to as well. 40 is the
    // 20px inset the drop shadow lives in, doubled.
    implicitHeight: Math.min(card.implicitHeight + 40, (screen ? screen.height : 1080) - 120)
    color: "transparent"

    anchors {
        bottom: true
        right: true
    }

    // --- CLICK OUTSIDE TO CLOSE ---
    HyprlandFocusGrab {
        windows: [root]
        active: root.isOpen && root.showWindow
        onCleared: {
            if (root.isOpen) root.isOpen = false
        }
    }

    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (root.isOpen) root.isOpen = false
        }
    }

    // --- ANIMATION LOGIC (Vertical Slide + Wayland Fix) ---
    property bool isOpen: false

    // Guard variable to prevent Wayland from unmapping the window too early
    property bool showWindow: false
    visible: showWindow

    onIsOpenChanged: {
        if (isOpen) {
            showWindow = true

            // Auto-refresh "Today" if the date changed while Quickshell was running
            let now = new Date();
            if (now.getDate() !== todayDate || now.getMonth() !== todayMonth) {
                todayDate = now.getDate()
                todayMonth = now.getMonth()
                todayYear = now.getFullYear()

                currentMonth = todayMonth
                currentYear = todayYear
                updateCalendar(currentYear, currentMonth)
            }
        }
    }

    // 45px clears the 55px bar by ~10px. The closed position has to be further
    // than the window is tall, and the window height is now variable.
    property real currentBottomMargin: isOpen ? 45 : -(root.implicitHeight + 60)

    margins {
        bottom: root.currentBottomMargin
        right: 0
    }

    Behavior on currentBottomMargin {
        NumberAnimation {
            duration: PanelStyle.animSlower
            easing.type: Easing.OutQuint

            // Unmap the window ONLY after the hide animation completely finishes
            onRunningChanged: {
                if (!running && !root.isOpen) root.showWindow = false
            }
        }
    }

    IpcHandler {
        target: "notifications"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- LIVE CLOCK ---
    property var now: new Date()
    Timer {
        // Only ticks while the panel is actually on screen.
        interval: 1000
        running: root.showWindow
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    // --- REUSABLE COMPONENTS ---
    component ActionIcon: Button {
        property string iconTxt: ""
        property string iconSrc: ""
        implicitWidth: 28
        implicitHeight: 28
        background: Rectangle { color: "transparent" }
        contentItem: Item {
            Text {
                anchors.centerIn: parent
                text: iconTxt
                visible: iconSrc === ""
                color: Theme.primary
                font.family: "monospace"
                font.pixelSize: 18
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
            }
            Image {
                anchors.centerIn: parent
                source: iconSrc
                width: 18
                height: 18
                sourceSize.width: 18
                sourceSize.height: 18
                visible: iconSrc !== ""
                fillMode: Image.PreserveAspectFit
                layer.enabled: iconSrc !== ""
                layer.effect: MultiEffect {
                    colorization: 1.0
                    colorizationColor: Theme.primary
                }
            }
        }
    }

    component PillButton: Button {
        id: pill
        // Not "highlighted": QtQuick Controls' Button already declares that one
        // FINAL, and shadowing it fails to load the whole config.
        property bool filled: false
        background: Rectangle {
            color: pill.filled ? Theme.primary : "transparent"
            border.color: Theme.primary
            border.width: 1
            radius: PanelStyle.controlRadius
        }
        contentItem: Text {
            text: pill.text
            font.family: Theme.fontFamily
            font.pixelSize: 12
            color: pill.filled ? Theme.background : Theme.primary
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            padding: Tokens.space.xs
            leftPadding: Tokens.space.lg
            rightPadding: Tokens.space.lg
        }
    }

    // --- CALENDAR LOGIC & DATA ---
    property var monthNames: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    property var dayNames: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    property int currentMonth: new Date().getMonth()
    property int currentYear: new Date().getFullYear()

    property int todayDate: new Date().getDate()
    property int todayMonth: new Date().getMonth()
    property int todayYear: new Date().getFullYear()

    ListModel { id: dayModel }
    ListModel { id: weekModel }

    Component.onCompleted: updateCalendar(currentYear, currentMonth)

    function prevMonth() {
        if (currentMonth === 0) {
            currentMonth = 11;
            currentYear--;
        } else {
            currentMonth--;
        }
        updateCalendar(currentYear, currentMonth);
    }

    function nextMonth() {
        if (currentMonth === 11) {
            currentMonth = 0;
            currentYear++;
        } else {
            currentMonth++;
        }
        updateCalendar(currentYear, currentMonth);
    }

    function updateCalendar(year, month) {
        dayModel.clear()
        weekModel.clear()

        let firstDay = new Date(year, month, 1)
        let startingDayOfWeek = firstDay.getDay()
        let startCell = startingDayOfWeek === 0 ? 6 : startingDayOfWeek - 1

        let daysInMonth = new Date(year, month + 1, 0).getDate()
        let daysInPrevMonth = new Date(year, month, 0).getDate()

        for (let row = 0; row < 6; row++) {
            let dateInRow = new Date(year, month, 1 + (row * 7) - startCell)
            let d = new Date(Date.UTC(dateInRow.getFullYear(), dateInRow.getMonth(), dateInRow.getDate()));
            d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay()||7));
            let yearStart = new Date(Date.UTC(d.getUTCFullYear(),0,1));
            let weekNo = Math.ceil(( ( (d - yearStart) / 86400000) + 1)/7);

            weekModel.append({ weekNumber: weekNo })
        }

        for (let i = 0; i < 42; i++) {
            if (i < startCell) {
                dayModel.append({ day: daysInPrevMonth - startCell + i + 1, isCurrentMonth: false, isToday: false })
            } else if (i >= startCell && i < startCell + daysInMonth) {
                let dayNum = i - startCell + 1
                let isTod = (dayNum === todayDate && month === todayMonth && year === todayYear)
                dayModel.append({ day: dayNum, isCurrentMonth: true, isToday: isTod })
            } else {
                dayModel.append({ day: i - startCell - daysInMonth + 1, isCurrentMonth: false, isToday: false })
            }
        }
    }

    // ==========================================
    // MAIN PANEL BACKGROUND
    // ==========================================
    Item {
        id: card
        anchors.fill: parent
        anchors.margins: PanelStyle.shadowMargin
        implicitHeight: content.implicitHeight + 40

        RectangularShadow {
            anchors.fill: mainBgRect
            radius: mainBgRect.radius
            blur: 15
            color: PanelStyle.shadowColor
        }

        // --- CARD ---
        //
        // One rectangle: translucent fill, solid hairline border.
        //
        // DO NOT reintroduce the gradient this used to have. A Rectangle has no
        // gradient *border* — a gradient is a fill, so it painted the whole card
        // and the "translucent" inner rectangle then composited against that
        // opaque gradient instead of against the wallpaper. The card was never
        // see-through: setting the inner alpha to 0.0 changed nothing on screen,
        // which is how it was proved. Masking the gradient down to a ring works
        // in principle but is a shader pass per panel for a 2px edge.
        //
        // Frosted glass: the translucency lives in this fill's alpha, never in
        // the card's `opacity`, which would fade the text and border with it.
        // The blur behind it comes from the "quickshell-frosted-glass" layer
        // rule in ~/.config/hypr/shehan/theming.lua.
        Rectangle {
            id: mainBgRect
            anchors.fill: parent
            radius: PanelStyle.panelRadius
            color: PanelStyle.panelColor
            border.width: PanelStyle.panelBorderWidth
            border.color: PanelStyle.panelBorderColor
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: PanelStyle.panelPadding
            spacing: Tokens.space.xxl

            // ---------- CLOCK ----------
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: Qt.formatDateTime(root.now, "HH:mm:ss")
                    color: Theme.primary
                    font.family: Theme.fontFamily
                    font.pixelSize: 56
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    Layout.fillWidth: true
                    text: Qt.formatDateTime(root.now, "dddd, d MMMM yyyy")
                    color: Theme.on_background
                    opacity: 0.7
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.primary; opacity: PanelStyle.dividerAlpha }

            // ---------- CALENDAR ----------
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 30

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 5

                    ActionIcon {
                        iconSrc: "../shared/icons/chevron-left.svg"
                        onClicked: prevMonth()
                    }

                    Text {
                        Layout.preferredWidth: 120
                        text: monthNames[currentMonth] + " " + currentYear
                        color: Theme.primary
                        font.family: Theme.fontFamily
                        font.pixelSize: 16
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                    }

                    ActionIcon {
                        iconSrc: "../shared/icons/chevron-right.svg"
                        onClicked: nextMonth()
                    }
                }

                PillButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Today"

                    opacity: (currentMonth !== todayMonth || currentYear !== todayYear) ? 1.0 : 0.0
                    enabled: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: PanelStyle.animSlow; easing.type: Easing.InOutQuad } }

                    onClicked: {
                        currentMonth = todayMonth;
                        currentYear = todayYear;
                        updateCalendar(currentYear, currentMonth);
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 230
                spacing: Tokens.space.xl

                ColumnLayout {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 24
                    spacing: Tokens.space.xs

                    Text {
                        Layout.fillWidth: true
                        text: "Wk"
                        color: Theme.on_background
                        opacity: 0.5
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        Layout.bottomMargin: Tokens.space.xs
                    }

                    Repeater {
                        model: weekModel
                        Text {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            text: model.weekNumber
                            color: Theme.primary
                            opacity: 0.7
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.primary; opacity: PanelStyle.dividerAlpha }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Tokens.space.xs

                    RowLayout {
                        Layout.fillWidth: true
                        Repeater {
                            model: root.dayNames
                            Text {
                                Layout.fillWidth: true
                                text: modelData
                                color: Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: 13
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    GridLayout {
                        columns: 7
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        rowSpacing: 4
                        columnSpacing: 4

                        Repeater {
                            model: dayModel

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: width / 2
                                color: model.isToday ? Theme.primary : "transparent"

                                Text {
                                    anchors.centerIn: parent
                                    text: model.day
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 13
                                    font.bold: model.isToday
                                    color: model.isToday ? Theme.background : Theme.on_background
                                    opacity: (model.isCurrentMonth || model.isToday) ? 1.0 : 0.3
                                }
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.primary; opacity: PanelStyle.dividerAlpha }

            // ---------- NOTIFICATIONS ----------
            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.md

                Text {
                    text: "Notifications"
                    color: Theme.primary
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    font.bold: true
                }

                Text {
                    visible: NotificationState.count > 0
                    text: NotificationState.count
                    color: Theme.on_background
                    opacity: Tokens.opacity.textDim
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                }

                Item { Layout.fillWidth: true }

                PillButton {
                    text: NotificationState.dnd ? "DND on" : "DND"
                    filled: NotificationState.dnd
                    onClicked: NotificationState.toggleDnd()
                }

                PillButton {
                    text: "Clear"
                    enabled: NotificationState.count > 0
                    opacity: enabled ? 1.0 : 0.4
                    onClicked: NotificationState.clearAll()
                }
            }

            // Empty state. Without this the card collapses to nothing the moment
            // the last notification is cleared, which reads as a bug.
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.space.md
                Layout.bottomMargin: Tokens.space.md
                visible: NotificationState.count === 0
                text: NotificationState.dnd ? "No notifications · DND on" : "No notifications"
                color: Theme.on_background
                opacity: 0.45
                font.family: Theme.fontFamily
                font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter
            }

            ListView {
                id: notificationList
                Layout.fillWidth: true
                visible: NotificationState.count > 0
                // Grows with the list, then scrolls. The cap is what keeps the
                // panel from running off the top of the screen.
                Layout.preferredHeight: Math.min(contentHeight, 320)
                clip: true
                spacing: Tokens.space.md
                model: NotificationState.list
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: NotificationEntry {
                    required property var modelData
                    notification: modelData
                    width: notificationList.width - (notificationList.ScrollBar.vertical.visible ? 12 : 0)
                }
            }
        }
    }
}
