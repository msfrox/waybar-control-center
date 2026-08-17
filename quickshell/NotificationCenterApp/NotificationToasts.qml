import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.CustomTheme

// The popups that replace the ones swaync used to draw.
//
// Bottom right, matching NotificationCenterWindow — the panel this is telling
// you to open already lives there ("45px clears the 55px bar by ~10px" is
// that file's own measurement, reused here verbatim). A toast that ARRIVES
// grows the stack upward from that fixed bottom edge, newest nearest the
// corner, exactly the way the panel itself grows.
//
// This window is always mapped but input-masked to the toasts themselves, so
// the empty area above the stack stays click-through.
PanelWindow {
    id: root

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell"
    exclusionMode: WlrLayershell.Ignore

    // No focus grab and no keyboard focus: a toast must never steal input from
    // whatever is being typed into.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
        bottom: true
        right: true
    }

    implicitWidth: 400
    implicitHeight: Math.max(1, toastList.contentHeight + 40)
    color: "transparent"

    visible: NotificationState.toasts.length > 0

    // Only the cards take clicks; the gaps between them and the space above do not.
    mask: Region { item: toastList }

    margins {
        bottom: 45
        right: 0
    }

    // --- KEEPING A REAL, INCREMENTALLY-UPDATED MODEL ---
    //
    // `NotificationState.toasts` is a `list<var>` reassigned WHOLESALE on every
    // arrival and every drop (`root.toasts = [...root.toasts, n]` / `.filter(...)`).
    // A Repeater bound straight to that property sees a brand new array each
    // time and has no way to tell "one item was appended" from "everything
    // changed" — it tears down and rebuilds every delegate on every single
    // notification, which is why an existing toast used to replay its slide-in
    // and a dismissed one just vanished with nothing animating out. `ListModel`
    // is the fix: `append`/`insert`/`remove` on it fire real per-row signals,
    // which is what `ListView`'s `add`/`remove`/`displaced` transitions need to
    // exist at all. This model is kept in lockstep with the singleton's array
    // by diffing on every change, rather than changing what the singleton
    // stores — `NotificationState.toasts` has exactly one consumer (this file).
    ListModel {
        id: toastModel
    }

    function syncToastModel(): void {
        const current = NotificationState.toasts

        // Remove rows whose notification is gone. Backwards, so removing one
        // does not shift the indices still to be checked.
        for (let i = toastModel.count - 1; i >= 0; i--) {
            const nid = toastModel.get(i).nid
            if (!current.some((n) => n.id === nid))
                toastModel.remove(i)
        }

        // Insert rows for anything new, at the position it belongs — `current`
        // is oldest-first, and the model has to stay in that order for the
        // stack to grow the way the header describes.
        for (let idx = 0; idx < current.length; idx++) {
            const n = current[idx]
            let found = false
            for (let i = 0; i < toastModel.count; i++) {
                if (toastModel.get(i).nid === n.id) {
                    found = true
                    break
                }
            }
            if (!found)
                toastModel.insert(idx, { nid: n.id, notif: n })
        }
    }

    Connections {
        target: NotificationState
        function onToastsChanged() { root.syncToastModel() }
    }

    Component.onCompleted: root.syncToastModel()

    ListView {
        id: toastList
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.margins: 20
        width: parent.width - 40
        height: Math.min(contentHeight, (root.screen ? root.screen.height : 1080) - 100)
        spacing: 8
        interactive: false
        // Newest is the highest index in `toastModel` (see syncToastModel);
        // the list itself still lays out top-to-bottom in index order, so
        // pinning the LIST's bottom edge is what puts the newest row nearest
        // the corner and lets the stack grow upward as more arrive.
        verticalLayoutDirection: ListView.TopToBottom

        model: toastModel

        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 220 }
            NumberAnimation {
                property: "x"
                from: toastList.width
                to: 0
                duration: 250
                easing.type: Easing.OutQuint
            }
        }

        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: 160 }
            NumberAnimation {
                property: "x"
                to: toastList.width
                duration: 200
                easing.type: Easing.InQuint
            }
        }

        // Without this, a card above/below the one that just entered or left
        // SNAPS into its new slot instead of sliding — the other half of the
        // "jagged mess" complaint, since two toasts arriving close together
        // would still have every survivor teleport once each new one landed.
        displaced: Transition {
            NumberAnimation { properties: "x,y"; duration: 200; easing.type: Easing.OutCubic }
        }

        delegate: Item {
            id: toast

            required property var notif
            required property int nid

            width: toastList.width
            implicitHeight: toastCard.implicitHeight

            RectangularShadow {
                anchors.fill: toastCard
                radius: toastCard.radius
                blur: 15
                color: Qt.rgba(Theme.shadow.r, Theme.shadow.g, Theme.shadow.b, 0.4)
            }

            // Same card as the panel: translucent fill, hairline border, and
            // no gradient. See the long comment in NotificationCenterWindow
            // for why a gradient here makes the card opaque.
            Rectangle {
                id: toastCard
                width: parent.width
                implicitHeight: toastEntry.implicitHeight + 4
                radius: 10
                color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.30)
                border.width: 1
                border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35)

                NotificationEntry {
                    id: toastEntry
                    anchors.fill: parent
                    anchors.margins: 2
                    notification: toast.notif
                    showBackground: false
                }
            }

            // Hovering holds the toast open — otherwise anything with an
            // action button is a race against the timer.
            HoverHandler { id: hover }

            Timer {
                interval: NotificationState.timeoutFor(toast.notif)
                // interval 0 means "until dismissed", so do not arm at all.
                running: interval > 0 && !hover.hovered
                repeat: false
                onTriggered: NotificationState.dropToast(toast.notif)
            }
        }
    }
}
