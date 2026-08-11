// Port of Waybar's `ext/workspaces` module (`"format": "{name}"`, `"sort-by-name": true`,
// `"active-only": false`, `"all-outputs": true`) for Hyprland. One pill per workspace
// that currently EXISTS — `Hyprland.workspaces.values` already reflects every output's
// live set, so `active-only`/`all-outputs` need no extra filtering here, and unlike
// StatusbarApp's own switcher (round dots, padded out to a minimum of 5) this does NOT
// pad to a fixed range: three workspaces exist right now and this shows exactly 1 2 3.
//
// Visual and interaction design is Waybar's `#workspaces` CSS as resolved by hand
// against `ml4w-modern/colored/style.css`'s colour remap (see BarButton.qml's header
// for the remap table) — not StatusbarApp's WorkspacesModule, which is good donor code
// for the Hyprland API (`usingLua`, `dispatch`, `focusedWorkspace`) but a completely
// different look.

import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import qs.CustomTheme

RowLayout {
    id: wsRoot

    // `#workspaces { margin: 0px 7px 0px 0px; min-width: 120px; }`. No left margin:
    // the sheet zeroes it for .modules-left's first child, and this module always
    // sits first in leftGroup.
    Layout.rightMargin: 7
    Layout.minimumWidth: 120
    Layout.alignment: Qt.AlignVCenter
    // The pills must stay packed against the left edge. GTK's `min-width: 120px`
    // widens the CONTAINER and leaves the slack empty on the right; a RowLayout
    // forced past its content width instead hands the slack to its items, which
    // pushed the pills 17px apart against Waybar's 6px. The filler at the end of
    // the Repeater below is what absorbs it.
    // leftGroup is anchored top+bottom in BarWindow, so ITS height is fixed
    // independent of children — fillHeight here inherits that fixed value safely.
    // Reading `parent.height` inside the pill delegate (the trick BarButton uses,
    // since ITS parent is leftGroup directly) would instead read wsRoot's own
    // height, which without fillHeight is derived FROM the children's implicit
    // size — a binding loop. fillHeight sidesteps it by taking the fixed value
    // from above rather than computing one from below.
    Layout.fillHeight: true
    spacing: 0

    // Sorted by name. Waybar does a plain string sort; `localeCompare(..., {numeric:
    // true})` instead puts "10" after "2" rather than between "1" and "2" — a
    // deliberate improvement, and unobservable difference for the 1-9 workspaces
    // actually in use, where both orderings agree.
    readonly property var sortedWorkspaces: {
        const list = Hyprland.workspaces.values.slice()
        list.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
        return list
    }

    // Click: jump straight to the workspace under the pointer. Quickshell's own
    // HyprlandWorkspace.activate() dispatches `hl.dsp.focus({ workspace = "%1" })` —
    // a quoted (string) target — which is the same shape StatusbarApp's donor code
    // uses, so pills match both the platform's own convention and the sibling app.
    // Hyprland 0.56 parses dispatch payloads as Lua and ignores the plain
    // "workspace N" string, hence the usingLua branch.
    function activate(ws): void {
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.focus({workspace = '" + ws.id + "'})")
        else
            Hyprland.dispatch("workspace " + ws.id)
    }

    // Scroll: relative move, computed here rather than shelled out to hyprctl.
    // Mirrors Waybar's own on-scroll dispatch verbatim (`hl.get_active_workspace().id
    // + 1`) — a bare numeric expression, unlike the quoted string `activate()` above
    // sends, because this is arithmetic Lua has to evaluate, not a literal target.
    function stepWorkspace(direction: int): void {
        if (!Hyprland.focusedWorkspace)
            return
        const target = Hyprland.focusedWorkspace.id + direction
        if (Hyprland.usingLua)
            Hyprland.dispatch("hl.dsp.focus({workspace = " + target + "})")
        else
            Hyprland.dispatch("workspace " + target)
    }

    // Touchpad smooth-scroll accumulator — see WheelHandler below.
    property real accumX: 0
    property real accumY: 0

    // Scroll anywhere over the module (not per-pill) steps the focused workspace by
    // one: up/left = -1, down/right = +1, matching Waybar's on-scroll-* mapping.
    // A WheelHandler on the root, rather than per-pill MouseArea.onWheel, is what
    // makes that "anywhere" true — the pills' own MouseAreas below only claim
    // clicks, so an unhandled wheel event over a pill still reaches this handler.
    //
    // "smooth-scrolling-threshold": 3 exists because a touchpad two-finger swipe is
    // a stream of tiny deltas, not one notch — without debouncing, one swipe flies
    // through several workspaces. A physical wheel notch always carries a pixelDelta
    // of (0,0) (angleDelta only, in multiples of 120); anything else is a touchpad
    // event, accumulated here until 3 notches' worth (360 angleDelta units) have
    // built up, then fired and reset — reproducing Waybar's threshold instead of
    // stepping on every micro-event.
    WheelHandler {
        onWheel: (event) => {
            const dx = event.angleDelta.x
            const dy = event.angleDelta.y
            const isDiscreteWheel = event.pixelDelta.x === 0 && event.pixelDelta.y === 0

            if (isDiscreteWheel) {
                if (dy !== 0)
                    wsRoot.stepWorkspace(dy > 0 ? -1 : 1)
                else if (dx !== 0)
                    wsRoot.stepWorkspace(dx > 0 ? 1 : -1)
                return
            }

            wsRoot.accumY += dy
            wsRoot.accumX += dx
            if (Math.abs(wsRoot.accumY) >= 3 * 120) {
                wsRoot.stepWorkspace(wsRoot.accumY > 0 ? -1 : 1)
                wsRoot.accumY = 0
                wsRoot.accumX = 0
            } else if (Math.abs(wsRoot.accumX) >= 3 * 120) {
                wsRoot.stepWorkspace(wsRoot.accumX > 0 ? 1 : -1)
                wsRoot.accumY = 0
                wsRoot.accumX = 0
            }
        }
    }

    Repeater {
        model: wsRoot.sortedWorkspaces

        delegate: Rectangle {
            id: pill
            required property var modelData // HyprlandWorkspace: .id, .name, ...

            readonly property bool isActive: Hyprland.focusedWorkspace
                && Hyprland.focusedWorkspace.id === pill.modelData.id

            // #workspaces button: 3px margin all round, 6px horizontal padding,
            // 2px border. GTK sizes the button from its content and does NOT stretch
            // it to the bar, so both dimensions are content-derived constants rather
            // than anything read off the parent — filling the height gave 46px pills
            // against Waybar's 34.7px, which read instantly as the wrong bar.
            //
            // The width arithmetic checks out against the live bar exactly:
            //   active   = 30 (the sheet's min-width) + 12 padding + 4 border = 46 -> measured 46.7
            //   inactive = 16                         + 12 padding + 4 border = 32 -> measured 32.7
            // That 16 is GTK Adwaita's default `button { min-width }`. The theme sheet
            // never restates it, so it is invisible in the CSS and is the reason a
            // pill sized purely from its label comes out ~12px too narrow.
            readonly property int contentFloor: pill.isActive ? 30 : 16

            Layout.margins: 3
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: 35
            Layout.preferredWidth: Math.max(pill.contentFloor, label.implicitWidth) + 16

            border.width: 2
            border.color: Theme.primary

            // .active and :hover both carry equal CSS specificity, so which one an
            // already-focused-but-hovered pill would show is genuinely ambiguous in
            // the source sheet. Judgement call: active wins, since the point of the
            // active style is to mark the CURRENT workspace and that should not
            // flicker away just because the pointer happens to be sitting on it.
            color: pill.isActive ? Theme.primary
                 : (mouse.containsMouse ? Theme.primary_container : Theme.secondary)
            radius: pill.isActive ? 12 : (mouse.containsMouse ? 15 : 8)

            Behavior on color {
                ColorAnimation { duration: 300; easing.type: Easing.InOutQuad }
            }
            Behavior on border.color {
                ColorAnimation { duration: 300; easing.type: Easing.InOutQuad }
            }
            Behavior on radius {
                NumberAnimation { duration: 300; easing.type: Easing.InOutQuad }
            }

            Text {
                id: label
                anchors.centerIn: parent
                text: pill.modelData.name
                font.family: Theme.fontFamily
                font.pixelSize: 16
                color: pill.isActive ? Theme.on_primary : Theme.on_secondary

                Behavior on color {
                    ColorAnimation { duration: 300; easing.type: Easing.InOutQuad }
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // No onWheel here — deliberately, so scroll passes through to the
                // module-wide WheelHandler above instead of stopping at whichever
                // pill the pointer happens to be over.
                onClicked: wsRoot.activate(pill.modelData)
            }
        }
    }

    // Absorbs whatever `Layout.minimumWidth: 120` adds beyond the pills' own width,
    // so the slack lands here rather than being shared out as extra gap between them.
    Item { Layout.fillWidth: true }
}
