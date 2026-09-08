// Bluetooth popup for the Waybar `bluetooth` module.
//
// Replaces rendering blueman's tray menu through rofi. That approach depended on
// blueman-applet being alive in the tray - close the tray icon and the module's
// click did nothing - and it inherited rofi's look rather than the bar's.
//
// Quickshell.Bluetooth talks to BlueZ over DBus directly, so there is no applet
// to keep running and no menu to scrape.
//
// The window chrome below (layer config, slide animation, focus grab, IPC) is
// deliberately duplicated from AudioWindow rather than factored out, matching how
// ML4W's own Calendar/Sidebar/Power windows are written. Factor it out when a
// fourth panel makes the duplication actually cost something.

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import qs.CustomTheme
import qs.Panels
import qs.BarApp // BarReveal

PanelWindow {
    id: root

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: WlrLayershell.Ignore

    implicitWidth: 420
    implicitHeight: Math.min(content.implicitHeight + 80, 900)
    color: "transparent"

    anchors {
        bottom: true
        right: true
    }

    property real currentBottomMargin: isOpen ? 45 : -1200

    margins {
        bottom: root.currentBottomMargin
        right: 0
    }

    property bool isOpen: false
    property bool showWindow: false
    visible: showWindow

    // See AudioWindow.qml's comment: BarReveal is a shared singleton, no IPC
    // round trip needed even across app directories in this one process.
    onIsOpenChanged: {
        if (isOpen) {
            showWindow = true
            // Only scan while the panel is actually on screen - discovery is
            // expensive and drains peripherals that answer it.
            if (adapter && adapter.enabled) adapter.discovering = true
            BarReveal.acquire("bluetooth")
        } else {
            if (adapter) adapter.discovering = false
            BarReveal.release("bluetooth")
            // Drop the keyboard cursor on close. Without this, reopening the
            // panel resumes a highlight computed against whatever the device
            // lists looked like when it was last open - and a scan run in the
            // meantime, or a device that connected from another client, means
            // that highlight can land on a row that is no longer where it was
            // (or gone). Opening should always start "no cursor", same as a
            // cold open - see KeyNav.qml's own header on why -1 is that state.
            nav.clear()
        }
    }

    Behavior on currentBottomMargin {
        NumberAnimation {
            duration: PanelStyle.animSlower
            easing.type: Easing.OutQuint
            onRunningChanged: if (!running && !root.isOpen) root.showWindow = false
        }
    }

    HyprlandFocusGrab {
        windows: [root]
        active: root.isOpen && root.showWindow
        onCleared: if (root.isOpen) root.isOpen = false
    }

    Shortcut {
        sequence: "Escape"
        onActivated: if (root.isOpen) root.isOpen = false
    }

    // --- KEYBOARD ---
    //
    // Shape copied from hyprbar's SwitcherWindow.qml (the audit's named
    // reference for "built right"): a bare Item over the whole window,
    // focused only while the panel is open, deciding what each key means by
    // asking `nav` (see the KeyNav instance and section list further down)
    // where the cursor currently is. No WlrLayershell.keyboardFocus change
    // here - NetworkWindow.qml:1102-1113 already proves a plain `focus:`
    // property is enough to reach keys through this panel's existing
    // HyprlandFocusGrab, and touching the layer's keyboard-focus mode risks
    // this panel holding the keyboard against the compositor.
    //
    // Deliberately no vim h/j/k/l here (unlike SwitcherWindow's grid, which
    // has no text entry to collide with). NetworkWindow already has a Wi-Fi
    // PSK TextInput, so a letter key that doubles as "move the cursor" is a
    // trap waiting for the day one of these panels grows a filter box.
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.isOpen

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Down:
                nav.moveBy(1)
                event.accepted = true
                break
            case Qt.Key_Up:
                nav.moveBy(-1)
                event.accepted = true
                break
            case Qt.Key_Tab:
                // Same one-key-does-two-things split SwitcherWindow uses for
                // Tab/Shift+Tab: the modifier picks the direction, so there is
                // one case rather than a separate Key_Backtab branch that can
                // silently stop matching if a future Qt/compositor combo
                // reports the shifted form differently.
                if (event.modifiers & Qt.ShiftModifier)
                    nav.moveBy(-1)
                else
                    nav.moveBy(1)
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
                root.activateCurrent()
                event.accepted = true
                break
            case Qt.Key_Delete:
            case Qt.Key_Backspace:
                // Header controls have nothing to forget, and forgetDevice()
                // itself re-checks paired/bonded before touching BlueZ - the
                // same guard the trailing close glyph's `visible:` already
                // uses - so a discovered-but-unpaired row under the cursor is
                // a no-op, not an accidental forget.
                if (nav.currentSection !== "header")
                    root.forgetDevice(nav.currentItem)
                event.accepted = true
                break
            }
        }
    }

    IpcHandler {
        target: "bluetooth"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- BLUEZ ---
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var allDevices: Bluetooth.devices ? Bluetooth.devices.values : []

    readonly property var connected: allDevices.filter(d => d.connected)
    // Paired-but-disconnected first, then anything else the scan turned up.
    readonly property var known: allDevices.filter(d => !d.connected && (d.paired || d.bonded))
    readonly property var discovered: allDevices.filter(d => !d.connected && !d.paired && !d.bonded && d.name)

    // BlueZ publishes a freedesktop icon name; map the handful that actually
    // show up to Material ligatures rather than shipping an icon theme.
    function deviceGlyph(dev) {
        const icon = dev && dev.icon ? dev.icon : ""
        if (icon.indexOf("headset") >= 0 || icon.indexOf("headphone") >= 0) return "headphones"
        if (icon.indexOf("audio") >= 0) return "speaker"
        if (icon.indexOf("mouse") >= 0) return "mouse"
        if (icon.indexOf("keyboard") >= 0) return "keyboard"
        if (icon.indexOf("phone") >= 0) return "smartphone"
        if (icon.indexOf("watch") >= 0) return "watch"
        if (icon.indexOf("computer") >= 0) return "computer"
        if (icon.indexOf("printer") >= 0) return "print"
        if (icon.indexOf("camera") >= 0) return "photo_camera"
        return "bluetooth"
    }

    // --- KEYBOARD NAV ---
    //
    // One KeyNav cursor over everything Tab should reach, in the order it is
    // drawn: the header row's three controls, then the three device lists.
    // See Panels/KeyNav.qml's header for why this is one flat index rather
    // than a per-section one - the short version is the same reason
    // SwitcherWindow.qml gave for windows-and-workspaces: moving the cursor
    // never needs to know which section it just left, only activating it does.
    //
    // The header controls are NOT a Repeater over a live array like the three
    // lists below - they are three fixed, hand-written pieces of UI (the
    // adapter Toggle, the Scan text, and the blueman-manager tune button).
    // KeyNav still wants them as one section so Tab does not skip the header
    // and land straight on the first device row. Each descriptor names WHICH
    // control it is ("kind") rather than leaning on its position in the
    // array, because the "scan" entry can disappear (adapter off or absent)
    // while the panel is open - a fixed row NUMBER would then silently
    // retarget onto whichever control happened to slide into that slot.
    readonly property var headerItems: {
        const items = [{ kind: "toggle" }]
        if (root.adapter && root.adapter.enabled)
            items.push({ kind: "scan" })
        items.push({ kind: "tune" })
        return items
    }

    // Mirrors each section's existing `visible:` binding below rather than
    // re-deriving it: KeyNav's own contract is that a section with items the
    // screen isn't showing lets the cursor land somewhere invisible, which
    // reads from the outside as "keyboard nav is broken" with no clue why.
    KeyNav {
        id: nav
        sections: [
            { id: "header", items: root.headerItems },
            { id: "connected", items: (root.adapter && root.adapter.enabled && root.connected.length > 0) ? root.connected : [] },
            { id: "known", items: (root.adapter && root.adapter.enabled && root.known.length > 0) ? root.known : [] },
            { id: "discovered", items: (root.adapter && root.adapter.enabled) ? root.discovered : [] }
        ]
    }

    // Is the keyboard cursor sitting on this particular header control? Named
    // by "kind" rather than by row number for the same reason `headerItems`
    // is built that way above - see that comment.
    function isHeaderCurrent(kind) {
        return nav.currentSection === "header" && nav.currentItem !== null && nav.currentItem.kind === kind
    }

    // THE one connect/disconnect/pair decision for a device, called from the
    // row's MouseArea and from Enter alike. Used to live inline in
    // DeviceRow.MouseArea.onClicked; pulled out here because BUGS.md already
    // priced what a second inline copy of this branch costs this project
    // ("one correct call site does not protect the second one").
    function activateDevice(dev) {
        if (!dev)
            return
        if (dev.connected) dev.disconnect()
        else if (dev.paired || dev.bonded) dev.connect()
        else dev.pair()
    }

    // THE one forget path, called from the row's trailing "close" glyph and
    // from Delete/Backspace alike. Re-checks paired/bonded itself rather than
    // trusting the caller: the glyph's own `visible:` already encodes "only a
    // paired/bonded device can be forgotten", but the keyboard path has no
    // equivalent gate for free, since the cursor can sit on any row.
    function forgetDevice(dev) {
        if (!dev)
            return
        if (dev.paired || dev.bonded) dev.forget()
    }

    // What Enter means, resolved against wherever the cursor currently is.
    // The header branch exists because those three controls are not devices
    // and each does something different when "activated"; the device branch
    // is the one function above, same as a click.
    function activateCurrent() {
        if (nav.currentSection === "header") {
            const kind = nav.currentItem ? nav.currentItem.kind : ""
            if (kind === "toggle") {
                if (root.adapter) root.adapter.enabled = !root.adapter.enabled
            } else if (kind === "scan") {
                if (root.adapter) root.adapter.discovering = !root.adapter.discovering
            } else if (kind === "tune") {
                Quickshell.execDetached(["blueman-manager"])
                root.isOpen = false
            }
            return
        }
        root.activateDevice(nav.currentItem)
    }

    // --- SHARED PIECES ---
    component Glyph: Text {
        font.family: "Material Icons Round"
        font.pixelSize: 20
        color: Theme.primary
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }

    component SectionLabel: Text {
        font.family: Theme.fontFamily
        font.pixelSize: 11
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1
        color: Theme.outline
        Layout.topMargin: Tokens.space.xs
    }

    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.primary
        opacity: PanelStyle.dividerAlpha
    }

    component Toggle: Rectangle {
        id: tgl
        property bool checked: false
        signal toggled

        implicitWidth: 40
        implicitHeight: 22
        radius: Tokens.radius.full
        color: checked ? Theme.primary : Qt.rgba(Theme.on_surface.r, Theme.on_surface.g, Theme.on_surface.b, Tokens.opacity.separator)
        Behavior on color { ColorAnimation { duration: PanelStyle.animNormal } }

        Rectangle {
            width: 16
            height: 16
            radius: Tokens.radius.full
            color: tgl.checked ? Theme.on_primary : Theme.background
            anchors.verticalCenter: parent.verticalCenter
            x: tgl.checked ? parent.width - width - 3 : 3
            Behavior on x { NumberAnimation { duration: PanelStyle.animNormal; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tgl.toggled()
        }
    }

    // One device. Primary click connects or disconnects; the trailing X forgets
    // a paired device, which is the only other thing anyone does from a popup.
    component DeviceRow: Rectangle {
        id: devRoot
        required property var dev
        // Which KeyNav section this row lives in ("connected"/"known"/
        // "discovered") and which row within it - set by each Repeater
        // below, the same way `dev` is. Needed so this one component can ask
        // `nav.isCurrent(sectionId, row)` regardless of which list it's in.
        required property string sectionId
        required property int row

        Layout.fillWidth: true
        implicitHeight: 40
        radius: Tokens.radius.sm
        // ADR-0018 rule 4: pointer and keyboard share one cursor, they do not
        // take turns. Hovering this row calls nav.setCurrent() below, so by
        // the time this binding runs, "the mouse is over this row" and "this
        // row is the keyboard cursor" are the SAME fact rather than two facts
        // that can disagree. That is why there is only one fill here now,
        // not `nav.isCurrent(...) || mouse.containsMouse` - the second half
        // of that OR can never be true without the first half also being
        // true. fillCursor (Theme.tertiary), not fillHover or fillSelected -
        // both of those are primary-tinted and already mean something else on
        // this row (plain mouse-over; "this is the connected/default one"),
        // so the KeyNav cursor gets its own hue rather than a third alpha of
        // the same one. See PanelStyle.fillCursor's own comment.
        color: nav.isCurrent(devRoot.sectionId, devRoot.row)
               ? PanelStyle.fillCursor
               : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Tokens.space.md
            anchors.rightMargin: Tokens.space.md
            spacing: Tokens.space.lg

            Glyph {
                text: root.deviceGlyph(devRoot.dev)
                font.pixelSize: 18
                color: devRoot.dev.connected ? Theme.primary : Theme.on_surface
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: devRoot.dev.name || devRoot.dev.deviceName || devRoot.dev.address
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    color: devRoot.dev.connected ? Theme.primary : Theme.on_surface
                    elide: Text.ElideRight
                }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: devRoot.dev.pairing ? "Pairing…"
                        : devRoot.dev.connected
                          ? (devRoot.dev.batteryAvailable
                             ? "Connected · " + Math.round(devRoot.dev.battery * 100) + "%"
                             : "Connected")
                          : ""
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    color: Theme.outline
                    elide: Text.ElideRight
                }
            }

            Glyph {
                text: "close"
                font.pixelSize: 15
                color: forget.containsMouse ? Theme.error : Theme.outline
                visible: devRoot.dev.paired || devRoot.dev.bonded

                MouseArea {
                    id: forget
                    anchors.fill: parent
                    anchors.margins: -6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.forgetDevice(devRoot.dev)
                }
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: Tokens.space.gutter   // leave the forget button its own hit area
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Moving the mouse onto a row moves the SAME cursor the arrow
            // keys move (ADR-0018 rule 4) - see the `color:` binding above
            // for why that lets this component use one fill instead of two.
            onEntered: nav.setCurrent(devRoot.sectionId, devRoot.row)
            onClicked: root.activateDevice(devRoot.dev)
        }
    }

    // ==========================================
    // PANEL
    // ==========================================
    Item {
        anchors.fill: parent
        anchors.margins: PanelStyle.shadowMargin

        RectangularShadow {
            anchors.fill: mainBgRect
            radius: mainBgRect.radius
            blur: 15
            color: PanelStyle.shadowColor
        }

        // One rectangle: translucent fill, solid hairline border. A gradient
        // is a FILL, not a border, so it painted the whole card and the
        // "translucent" inner rectangle composited against that opaque
        // gradient rather than against the wallpaper - never actually
        // see-through. Blur comes from the "quickshell-frosted-glass" layer
        // rule in ~/.config/hypr/shehan/theming.lua.
        Rectangle {
            id: mainBgRect
            anchors.fill: parent
            radius: PanelStyle.panelRadius
            color: PanelStyle.panelColor
            border.width: 1
            border.color: PanelStyle.panelBorderColor
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: PanelStyle.panelPadding
            spacing: PanelStyle.panelSpacing

            // --- HEADER ---
            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.lg

                Text {
                    Layout.fillWidth: true
                    text: "Bluetooth"
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                    font.bold: true
                    color: Theme.primary
                }

                Toggle {
                    checked: root.adapter ? root.adapter.enabled : false
                    enabled: root.adapter !== null
                    onToggled: if (root.adapter) root.adapter.enabled = !root.adapter.enabled
                    // Keyboard cursor. A fillCursor plate (DeviceRow's
                    // approach) would fight this control's own fill, which
                    // already carries meaning - on is Theme.primary, off is
                    // not - so the cursor here is a ring around that fill
                    // rather than a second fill on top of it. Theme.tertiary
                    // to match fillCursor's own reasoning (PanelStyle.qml):
                    // the cursor gets a hue nothing else on this row already
                    // uses, rather than reusing primary for a fourth thing.
                    border.width: root.isHeaderCurrent("toggle") ? Tokens.size.border : 0
                    border.color: Theme.tertiary
                }

                Rectangle {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: PanelStyle.buttonRadius
                    color: settingsMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"
                    // Same ring approach as the Toggle above, and for the same
                    // reason: this Rectangle's `color` is already hover's fill,
                    // so the keyboard cursor gets the border instead of a
                    // second, competing fill - and the same Theme.tertiary,
                    // so a cursor looks like the same cursor everywhere in
                    // this panel rather than one colour on rows and another
                    // on the header.
                    border.width: root.isHeaderCurrent("tune") ? Tokens.size.border : 0
                    border.color: Theme.tertiary

                    ToolTip.visible: settingsMouse.containsMouse
                    ToolTip.text: "Open the full blueman manager"
                    ToolTip.delay: 400

                    Glyph { anchors.centerIn: parent; text: "tune"; font.pixelSize: 17 }

                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["blueman-manager"])
                            root.isOpen = false
                        }
                    }
                }
            }

            Divider {}

            // --- OFF / NO ADAPTER ---
            Text {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.space.sm
                visible: !root.adapter || !root.adapter.enabled
                text: root.adapter ? "Bluetooth is off" : "No Bluetooth adapter"
                font.family: Theme.fontFamily
                font.pixelSize: 12
                color: Theme.outline
                leftPadding: Tokens.space.md
            }

            // --- CONNECTED ---
            SectionLabel {
                text: "Connected"
                visible: root.adapter && root.adapter.enabled && root.connected.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.adapter && root.adapter.enabled && root.connected.length > 0

                Repeater {
                    model: root.connected
                    DeviceRow {
                        required property var modelData
                        required property int index
                        dev: modelData
                        sectionId: "connected"
                        row: index
                    }
                }
            }

            // --- PAIRED ---
            SectionLabel {
                text: "Paired"
                visible: root.adapter && root.adapter.enabled && root.known.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.adapter && root.adapter.enabled && root.known.length > 0

                Repeater {
                    model: root.known
                    DeviceRow {
                        required property var modelData
                        required property int index
                        dev: modelData
                        sectionId: "known"
                        row: index
                    }
                }
            }

            // --- DISCOVERED ---
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Tokens.space.xs
                visible: root.adapter && root.adapter.enabled

                SectionLabel { Layout.fillWidth: true; text: "Available" }

                Text {
                    text: root.adapter && root.adapter.discovering ? "Scanning…" : "Scan"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    // Text has no border, so the keyboard cursor can't get the
                    // ring the two boxed header controls get above. Keyboard-
                    // current uses Theme.tertiary (same cursor colour as
                    // everywhere else in this panel); hover keeps its own
                    // existing Theme.primary swap rather than being folded
                    // into the cursor colour, since a mouse resting here
                    // without having moved the cursor (see point 4's header
                    // controls note) is not actually the KeyNav cursor.
                    color: root.isHeaderCurrent("scan")
                           ? Theme.tertiary
                           : (scanMouse.containsMouse ? Theme.primary : Theme.outline)

                    ToolTip.visible: scanMouse.containsMouse
                    ToolTip.text: "Start or stop scanning for nearby devices"
                    ToolTip.delay: 400

                    MouseArea {
                        id: scanMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: if (root.adapter) root.adapter.discovering = !root.adapter.discovering
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.adapter && root.adapter.enabled

                Repeater {
                    model: root.discovered
                    DeviceRow {
                        required property var modelData
                        required property int index
                        dev: modelData
                        sectionId: "discovered"
                        row: index
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.adapter && root.adapter.enabled && root.discovered.length === 0
                text: root.adapter && root.adapter.discovering
                      ? "Looking for devices…"
                      : "No new devices"
                font.family: Theme.fontFamily
                font.pixelSize: 11
                color: Theme.outline
                leftPadding: Tokens.space.md
            }

            Item { Layout.fillHeight: true }
        }
    }
}
