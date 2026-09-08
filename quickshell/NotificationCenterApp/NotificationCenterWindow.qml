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
import qs.BarApp // BarReveal

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

    // See AudioWindow.qml's comment: BarReveal is a shared singleton, no IPC
    // round trip needed even across app directories in this one process.
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
            BarReveal.acquire("notifications")
        } else {
            BarReveal.release("notifications")
            // Reopening starts clean rather than resuming a highlight on a
            // notification that may since have been dismissed elsewhere
            // (e.g. by the sending app) while the panel was closed.
            nav.clear()
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
    //
    // Both of these are QQC2 Buttons, and both get `focusPolicy: Qt.NoFocus`
    // — see the "--- KEYBOARD NAVIGATION ---" section below for the finding
    // that made this necessary (QQC2 Buttons default to Qt.StrongFocus on
    // Linux, which fights the KeyNav cursor for what Tab/Enter mean). Fixed
    // at the component level rather than per instance so it also covers the
    // calendar's chevrons and "Today" pill, which are NOT part of any
    // KeyNav section but share these components — leaving them focusable
    // would still let a single click on "Today" steal keyboard focus away
    // from `keyCatcher` and quietly break every key handled below.
    component ActionIcon: Button {
        property string iconTxt: ""
        property string iconSrc: ""
        focusPolicy: Qt.NoFocus
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
        // Set from `nav.isCurrent("header", ...)` by the two instances below
        // that are actually part of a KeyNav section (DND, Clear) — the
        // calendar's "Today" pill never binds this and stays permanently
        // false, which is correct: it isn't part of any section.
        property bool navHighlighted: false
        focusPolicy: Qt.NoFocus
        background: Rectangle {
            // `filled` (the DND-is-on state) wins the fill when both are
            // true rather than fighting navHighlighted for it — the border
            // thickening still shows the cursor is here even then, and a
            // second, competing fill colour on top of "on" would read as a
            // third state nobody asked for. Deliberately fillSelected, not
            // fillHover — PanelStyle names fillSelected as the one every
            // popup already uses for "the keyboard/selection is on this
            // row", and reusing fillHover here would make the keyboard
            // cursor look like a mouse that never left.
            color: pill.filled ? Theme.primary : (pill.navHighlighted ? PanelStyle.fillSelected : "transparent")
            border.color: Theme.primary
            border.width: pill.navHighlighted ? 2 : 1
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

    // --- KEYBOARD NAVIGATION ---
    //
    // See Panels/KeyNav.qml's header for the shared mechanism (all three
    // panels the 2026-09-07 audit found broken use it) and why it exists.
    //
    // THE QQC2-FOCUS FINDING, established before writing any of this rather
    // than assumed: this panel is the odd one out among the three, because
    // its header pills and each notification's action buttons are QQC2
    // Buttons, not bare MouseAreas. Checked against qtdeclarative's own
    // source (src/quicktemplates/qquickabstractbutton.cpp) rather than
    // recalled from memory: on Linux, QQuickAbstractButton's `init()` sets
    // `focusPolicy: Qt.StrongFocus` (only macOS gets the milder TabFocus), and
    // Return/Space on a focused Button fire clicked() through Qt's own
    // platform-theme-driven key handling — entirely outside this file. So
    // clicking OR tabbing to "DND", "Clear", "Today", a calendar chevron, or
    // a notification's own action button ALREADY moves native Qt keyboard
    // focus today, with no code of ours involved. Left alone that is a
    // SECOND cursor: QQC2's own (invisible here — neither Button subclass
    // below drew a focus ring) disagreeing with KeyNav's highlighted one
    // about what Enter means, and a stray click anywhere handing focus away
    // from `keyCatcher` below so Tab/Down/Up would quietly stop doing
    // anything at all.
    //
    // Fix: `focusPolicy: Qt.NoFocus` on the ActionIcon and PillButton
    // components (above) and on each notification's action Button
    // (NotificationEntry.qml) — every QQC2 control in this window. One
    // cursor, KeyNav's, moved only by the key handler below.
    KeyNav {
        id: nav
        // Lightweight descriptor objects for the header, matching what
        // clicking each pill already does further down; the notification
        // rows are the live model itself, same object NotificationEntry
        // binds `notification:` to, so a row's flat position and its actual
        // data can never disagree. Both are always-visible in this file
        // (the header title row has no `visible:` binding, and `list` is
        // already empty exactly when the ListView below hides itself), so
        // neither section needs the empty-when-hidden filtering the header
        // comment in KeyNav.qml warns about.
        sections: [
            { id: "header", items: [{ id: "dnd" }, { id: "clear" }] },
            { id: "notifications", items: NotificationState.list }
        ]
    }

    // Arrowing/Tabbing past the bottom of the (capped-height, scrollable)
    // notification list must not leave the highlight somewhere the user
    // can't see — the list is unbounded, so this is the panel where that
    // certainly matters. Only "notifications" ever needs it: the header
    // sits above the list and is always fully on screen.
    Connections {
        target: nav
        function onMoved(index) {
            if (nav.currentSection === "notifications" && nav.currentRow >= 0)
                notificationList.positionViewAtIndex(nav.currentRow, ListView.Contain)
        }
    }

    // --- ROW ACTIONS ---
    //
    // Exactly one implementation of each, called from both the mouse
    // handlers in NotificationEntry.qml and the key handler below — BUGS.md
    // records what a second, drifted copy of a "correct" call site cost this
    // project before ("one correct call site does not protect the second
    // one").
    function dismiss(n: var): void {
        // Dismissing removes the very row the cursor is standing on.
        // KeyNav's own onCountChanged clamp (its header comment explains
        // why) already keeps `index` inside bounds when this was the LAST
        // row — and because the header's two items always occupy flat
        // indices 0 and 1 ahead of every notification, clamping the last
        // notification away rolls the cursor back onto "Clear" rather than
        // off the edge of the world. No empty-list special case is needed
        // here for that reason.
        //
        // What the automatic clamp does NOT do is emit `moved`: it assigns
        // `nav.index` directly rather than going through setIndex() (see
        // KeyNav.qml), so nothing tells the list to scroll the new position
        // into view. Recomputing the same target here, and scrolling
        // explicitly rather than trusting `moved` alone, is what makes a
        // last-row dismissal actually visible instead of merely correct:
        // setIndex() itself would be a silent no-op whenever the automatic
        // clamp already landed on the same number.
        const wasIndex = nav.index
        NotificationState.dismiss(n)
        if (wasIndex < 0) return
        nav.setIndex(Math.min(wasIndex, nav.count - 1))
        if (nav.currentSection === "notifications" && nav.currentRow >= 0)
            notificationList.positionViewAtIndex(nav.currentRow, ListView.Contain)
    }

    function invokeDefault(n: var): void {
        const acts = (n && n.actions) ? n.actions : []
        const def = acts.find(a => a.identifier === "default")
        // Most senders never register one — Enter on a row with none is a
        // deliberate no-op, not a missing feature. (Nothing in this file's
        // MOUSE handling invokes a default action either: nothing here ever
        // wired the notification body itself to a click. That is a gap in
        // the spec this was built from, not something this file invented —
        // flagged rather than silently "fixed" by adding new mouse behaviour
        // nobody asked for.)
        if (!def) return
        def.invoke()
        if (!n.resident) NotificationState.dropToast(n)
    }

    function invokeAction(n: var, index: int): void {
        const acts = (n && n.actions) ? n.actions : []
        const act = acts[index]
        if (!act) return
        act.invoke()
        if (!n.resident) NotificationState.dropToast(n)
    }

    // One Item, one Keys.onPressed, every key this panel understands routed
    // through the nav/root.* surface above — never a second place that also
    // knows how to dismiss a notification or toggle DND.
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.isOpen

        Keys.onPressed: event => {
            // Shift+Tab is "previous" — checked ahead of the switch below
            // because a bare `case Qt.Key_Tab` can't see modifiers.
            if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier)) {
                nav.moveBy(-1)
                event.accepted = true
                return
            }

            switch (event.key) {
            case Qt.Key_Down:
            case Qt.Key_Tab:
                nav.moveBy(1)
                event.accepted = true
                break
            case Qt.Key_Up:
                nav.moveBy(-1)
                event.accepted = true
                break
            case Qt.Key_Home:
                nav.first()
                event.accepted = true
                break
            case Qt.Key_End:
                nav.last()
                event.accepted = true
                break
            case Qt.Key_Return:
            case Qt.Key_Enter:
                // Branches on section exactly the way SwitcherWindow's
                // commit() branches on entry.type — moving the cursor never
                // needs to know what kind of thing it is over; only
                // activating it does.
                if (nav.currentSection === "header") {
                    const id = nav.currentItem ? nav.currentItem.id : ""
                    if (id === "dnd") NotificationState.toggleDnd()
                    else if (id === "clear" && NotificationState.count > 0) NotificationState.clearAll()
                } else if (nav.currentSection === "notifications") {
                    root.invokeDefault(nav.currentItem)
                }
                event.accepted = true
                break
            case Qt.Key_Delete:
            case Qt.Key_Backspace:
                // The single most valuable key in this panel — the one a
                // human will test first.
                if (nav.currentSection === "notifications" && nav.currentItem)
                    root.dismiss(nav.currentItem)
                event.accepted = true
                break
            default:
                // 1-9 invoke a notification's own action by position. Most
                // notifications carry none at all (NotificationState.qml's
                // `snapshotOf()` deliberately saves history entries with
                // `actions: []`), so this is a no-op far more often than
                // not — that is correct, not a bug.
                if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9
                        && nav.currentSection === "notifications" && nav.currentItem) {
                    const i = event.key - Qt.Key_1
                    const acts = nav.currentItem.actions || []
                    if (i < acts.length) {
                        root.invokeAction(nav.currentItem, i)
                        event.accepted = true
                    }
                }
                break
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
                    navHighlighted: nav.isCurrent("header", "dnd")
                    onClicked: NotificationState.toggleDnd()
                }

                PillButton {
                    text: "Clear"
                    enabled: NotificationState.count > 0
                    opacity: enabled ? 1.0 : 0.4
                    navHighlighted: nav.isCurrent("header", "clear")
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
                    required property int index
                    notification: modelData
                    width: notificationList.width - (notificationList.ScrollBar.vertical.visible ? 12 : 0)
                    highlighted: nav.isCurrent("notifications", index)
                    onHoverEntered: nav.setCurrent("notifications", index)
                    onDismissRequested: root.dismiss(modelData)
                    onActionRequested: (i) => root.invokeAction(modelData, i)
                }
            }
        }
    }
}
