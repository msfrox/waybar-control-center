import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import qs.CustomTheme
import qs.Panels

// The popups that replace the ones swaync used to draw.
//
// Default is bottom right, matching NotificationCenterWindow — the panel
// this is telling you to open already lives there ("45px clears the 55px
// bar by ~10px" is that file's own measurement, reused here verbatim). A
// toast that ARRIVES grows the stack upward from that fixed bottom edge,
// newest nearest the corner, exactly the way the panel itself grows.
//
// Position, animation and font are configurable on hyprsys' Notifications
// page (`NotificationState.position`/`animation`/`font`, read live from
// `~/.config/hyprbar/notifications.json` there) — see this file's `row`/
// `col` below for how one of 9 positions maps to anchors, and `animDuration`/
// `doSlide`/`doScale` for how "fade"/"slide"/"scale"/"none" map to the
// add/remove transitions further down.
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

    // --- POSITION: one of 9 values, default bottom-right -----------------
    function toastRow(pos: string): string {
        if (pos.startsWith("top")) return "top"
        if (pos.startsWith("bottom")) return "bottom"
        return "middle"        // "middle-left" / "middle-right" / "center"
    }
    function toastCol(pos: string): string {
        if (pos.endsWith("left")) return "left"
        if (pos.endsWith("right")) return "right"
        return "center"        // "top-center" / "bottom-center" / "center"
    }
    readonly property string row: root.toastRow(NotificationState.position)
    readonly property string col: root.toastCol(NotificationState.position)

    anchors {
        top: root.row === "top"
        bottom: root.row === "bottom"
        left: root.col === "left"
        right: root.col === "right"
    }

    implicitWidth: 400
    implicitHeight: Math.max(1, toastList.contentHeight + 40)
    color: "transparent"

    visible: NotificationState.toasts.length > 0

    // Only the cards take clicks; the gaps between them and the space above do not.
    mask: Region { item: toastList }

    //: 45/0 (bottom/right) is the ORIGINAL hardcoded pair, kept verbatim so
    //: the default position looks pixel-identical to before this batch.
    //: `edgeGutter` is the new, generic gutter every other row/col combo
    //: uses — this repo has no live signal for where the bar itself sits
    //: (top vs bottom), so a toast anchored to a top position on a
    //: top-bar setup may want more clearance than this; flagged, not
    //: solved, here.
    readonly property int barClearance: 45
    readonly property int edgeGutter: 12
    margins {
        top: root.row === "top" ? root.edgeGutter : 0
        bottom: root.row === "bottom" ? root.barClearance : 0
        left: root.col === "left" ? root.edgeGutter : 0
        right: root.col === "right" ? 0 : 0
    }

    // --- ANIMATION: fade / slide / scale / none ---------------------------
    //
    // `NotificationState.animation` ("none"/"slide"/"scale") is an animation
    // KIND, not a speed — B4.1 migration left it exactly as it was. Speed and
    // easing, below, now come from the shared appearance resolver instead of
    // being hardcoded per NumberAnimation:
    //
    //   - The opacity fade (`animDuration`, both add and remove — this is the
    //     one duration that was already shared between the two) was a bare
    //     220ms. Nearest tier by distance: |220-160|=40 vs |220-260|=60 puts
    //     it 20ms closer to "slow" (260) than "normal" (160) — kept as "slow".
    //   - The add transition's slide/scale duration was already
    //     `PanelStyle.animSlow` (== Tokens.motion.duration.slow, 260) — an
    //     exact match for tier "slow", so that one call site had no rounding
    //     decision to make.
    //   - The remove transition's slide/scale duration and the `displaced`
    //     reflow duration were both a bare 200ms. |200-160|=40 vs
    //     |200-260|=60 puts 200 closer to "normal" (160) — kept as "normal".
    //     This does shave 40ms off the old exit speed; not perceptible at
    //     this scale, and consistent nearest-tier reasoning beats a bespoke
    //     "300" tier existing nowhere else.
    //
    // Easing.OutQuint (enter slide), Easing.InQuint (exit slide/scale) and
    // Easing.OutCubic (displaced reflow) were each a fixed Qt curve with no
    // per-surface control. All three move to `Brilliant.easingCurve()` -- and
    // each passes the ROLE it is playing, which is what preserves the
    // asymmetry those three curves encoded. A first cut of this migration
    // dropped the role and put entrances and exits on one curve; a toast that
    // eases in on the way out reads as broken rather than as styled, so the
    // direction is meaning, not decoration. Entrances decelerate, exits
    // accelerate, and the displaced reflow -- which has no direction to
    // express -- takes the surface's own easing.
    // WORTH FLAGGING: the resolver has exactly one easing per surface, not
    // one per transition role — so enter and exit now animate on the SAME
    // curve where they used to differ (ease-out on the way in, ease-in on
    // the way out). That symmetry loss is the resolver's model working as
    // designed (one "animation.easing" setting per surface, from B4.1), not
    // an oversight, but it is a real, visible behaviour change from today.
    //
    // Easing.OutBack on the scale-in (add transition, `scale` animation) is
    // NOT migrated — its overshoot is a deliberate visual (the toast
    // "pops"), not a default easing standing in for "whatever the system
    // uses", so it stays a literal curve. Its duration still comes from the
    // resolver, since duration and easing are orthogonal knobs.
    readonly property bool animOn: NotificationState.animation !== "none"
    readonly property int animDuration: root.animOn ? Brilliant.duration("notification-toasts", "slow") : 0
    readonly property bool doSlide: NotificationState.animation === "slide"
    readonly property bool doScale: NotificationState.animation === "scale"

    // Slide direction follows whichever edge the toast is anchored to —
    // horizontal for a left/right column, vertical for the center column
    // (top/bottom row, or straight down for a fully-centered toast).
    function slideOffsetX(): real {
        if (!root.doSlide) return 0
        if (root.col === "left") return -toastList.width
        if (root.col === "right") return toastList.width
        return 0
    }
    function slideOffsetY(): real {
        if (!root.doSlide || root.col !== "center") return 0
        return root.row === "top" ? -80 : 80
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
        // Pinned to whichever edge(s) the window itself is anchored to
        // (see `root.row`/`root.col` above) — the vertical pin is what lets
        // the stack grow away from the corner as more toasts arrive; see
        // `verticalLayoutDirection` below for how "which end is newest"
        // flips between a top and a bottom row.
        anchors.top: root.row === "top" ? parent.top : undefined
        anchors.bottom: root.row === "bottom" ? parent.bottom : undefined
        // "middle" (middle-left/middle-right/center) has no top/bottom pin
        // at all -- vertically center instead, or the list would default to
        // the parent's top-left origin.
        anchors.verticalCenter: root.row === "middle" ? parent.verticalCenter : undefined
        anchors.left: root.col === "left" ? parent.left : undefined
        anchors.right: root.col === "right" ? parent.right : undefined
        anchors.horizontalCenter: root.col === "center" ? parent.horizontalCenter : undefined
        anchors.margins: PanelStyle.shadowMargin
        width: parent.width - 40
        height: Math.min(contentHeight, (root.screen ? root.screen.height : 1080) - 100)
        spacing: Tokens.space.md
        interactive: false
        // Newest is the highest index in `toastModel` (see syncToastModel).
        // For a bottom-anchored row, pinning the LIST's bottom edge (above)
        // plus normal top-to-bottom layout puts the newest row nearest the
        // corner and lets the stack grow upward as more arrive. For a
        // top-anchored row that has to mirror: BottomToTop layout puts index
        // 0 (oldest) at the list's own visual bottom and the newest nearest
        // the pinned top edge instead, with the stack growing downward.
        verticalLayoutDirection: root.row === "top" ? ListView.BottomToTop : ListView.TopToBottom

        model: toastModel

        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.animDuration }
            NumberAnimation {
                property: "x"
                from: root.slideOffsetX()
                to: 0
                duration: root.doSlide ? Brilliant.duration("notification-toasts", "slow") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "decelerate")
            }
            NumberAnimation {
                property: "y"
                from: root.slideOffsetY()
                to: 0
                duration: root.doSlide ? Brilliant.duration("notification-toasts", "slow") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "decelerate")
            }
            NumberAnimation {
                property: "scale"
                from: root.doScale ? 0.8 : 1
                to: 1
                duration: root.doScale ? Brilliant.duration("notification-toasts", "slow") : 0
                // Deliberate overshoot, not a default standing in for "whatever
                // curve the system uses" — left as a literal Qt curve. See the
                // ANIMATION comment block above.
                easing.type: Easing.OutBack
            }
        }

        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: root.animDuration }
            NumberAnimation {
                property: "x"
                to: root.slideOffsetX()
                duration: root.doSlide ? Brilliant.duration("notification-toasts", "normal") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "accelerate")
            }
            NumberAnimation {
                property: "y"
                to: root.slideOffsetY()
                duration: root.doSlide ? Brilliant.duration("notification-toasts", "normal") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "accelerate")
            }
            NumberAnimation {
                property: "scale"
                to: root.doScale ? 0.8 : 1
                duration: root.doScale ? Brilliant.duration("notification-toasts", "normal") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "accelerate")
            }
        }

        // Without this, a card above/below the one that just entered or left
        // SNAPS into its new slot instead of sliding — the other half of the
        // "jagged mess" complaint, since two toasts arriving close together
        // would still have every survivor teleport once each new one landed.
        // Skipped (duration 0) when "none" is selected, same as add/remove.
        displaced: Transition {
            NumberAnimation {
                properties: "x,y"
                duration: root.animOn ? Brilliant.duration("notification-toasts", "normal") : 0
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Brilliant.easingCurve("notification-toasts", "standard")
            }
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
                color: PanelStyle.shadowColor
            }

            // Same card as the panel: translucent fill, hairline border, and
            // no gradient. See the long comment in NotificationCenterWindow
            // for why a gradient here makes the card opaque.
            Rectangle {
                id: toastCard
                width: parent.width
                implicitHeight: toastEntry.implicitHeight + 4
                radius: PanelStyle.panelRadius
                color: PanelStyle.panelColor
                border.width: PanelStyle.panelBorderWidth
                border.color: PanelStyle.panelBorderColor

                NotificationEntry {
                    id: toastEntry
                    anchors.fill: parent
                    anchors.margins: Tokens.space.xxs
                    notification: toast.notif
                    showBackground: false
                    fontOverride: NotificationState.font
                    fontSizeOverride: NotificationState.fontSize
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
