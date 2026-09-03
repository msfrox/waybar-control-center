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

        Layout.fillWidth: true
        implicitHeight: 40
        radius: Tokens.radius.sm
        color: mouse.containsMouse
               ? PanelStyle.fillHover
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
                    onClicked: devRoot.dev.forget()
                }
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: Tokens.space.gutter   // leave the forget button its own hit area
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (devRoot.dev.connected) devRoot.dev.disconnect()
                else if (devRoot.dev.paired || devRoot.dev.bonded) devRoot.dev.connect()
                else devRoot.dev.pair()
            }
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
                }

                Rectangle {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: PanelStyle.buttonRadius
                    color: settingsMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"

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
                        dev: modelData
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
                        dev: modelData
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
                    color: scanMouse.containsMouse ? Theme.primary : Theme.outline

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
                        dev: modelData
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
