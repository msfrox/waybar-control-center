// Network popup for the Waybar `network` module.
//
// Replaces rendering nm-applet's tray menu through rofi - same reasoning as
// BluetoothApp: that depended on nm-applet living in the tray, and looked like
// rofi rather than like the bar. Quickshell.Networking talks to NetworkManager
// over DBus directly.
//
// Window chrome is duplicated from AudioWindow on purpose; see the note at the
// top of BluetoothWindow.qml.

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Networking
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
            // Scanning only while visible - a background scan on every wifi
            // device is a real power cost for a list nobody is looking at.
            if (wifiDevice) wifiDevice.scannerEnabled = true
            BarReveal.acquire("network")
        } else {
            if (wifiDevice) wifiDevice.scannerEnabled = false
            pskFor = null
            pskText = ""
            BarReveal.release("network")
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
        target: "network"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- EXTRA DETAIL (link rate, addressing, Tailscale) ---
    //
    // Quickshell.Networking models what NetworkManager exposes as objects, which
    // stops short of link rate and channel frequency, and knows nothing about
    // Tailscale. Rather than scattering Process blocks through this file, one
    // helper script returns all of it as a single JSON object.
    property var details: ({})

    Process {
        id: detailsProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/network-details.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.details = JSON.parse(this.text)
                } catch (e) {
                    root.details = {}
                }
            }
        }
    }

    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        // Only while the panel is on screen - this shells out to nmcli and
        // tailscale, which is not something to do every five seconds forever.
        running: root.isOpen
        onTriggered: if (!detailsProc.running) detailsProc.running = true
    }

    // --- THROUGHPUT ---
    //
    // Own Process and its own, faster tick, deliberately separate from the
    // details poll above: network-throughput.py is a couple of /proc file
    // reads with no subprocess, cheap enough for a 2s tick that makes the
    // graph actually look like it's moving, where 5s exists specifically to
    // keep the nmcli/tailscale calls infrequent. This used to be two InfoPills
    // in the Control Center's System section (Down/Up rate only, no totals,
    // no history) - moved here because throughput is a network fact, not a
    // system one, and gained the totals/peak/graph the pills never had room for.
    property var throughput: ({})

    Process {
        id: throughputProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/network-throughput.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.throughput = JSON.parse(this.text)
                } catch (e) {
                    root.throughput = {}
                }
            }
        }
    }

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.isOpen
        onTriggered: if (!throughputProc.running) throughputProc.running = true
    }

    // "" means auto: follow the backend's default-route pick (root.throughput.default)
    // rather than pinning to whatever that happened to be on the first read, so
    // it keeps tracking correctly through a wifi/ethernet handover. Picking an
    // explicit interface (or "total") in the dropdown below overrides that.
    property string selectedIface: ""
    property bool ifaceMenuOpen: false

    readonly property var throughputEntry: {
        const byIface = root.throughput.by_iface || {}
        const auto = root.throughput.default
        const key = root.selectedIface !== "" ? root.selectedIface
                  : (auto && byIface[auto] ? auto : "total")
        return byIface[key] || {}
    }

    function humanBytes(bytes) {
        if (bytes === null || bytes === undefined) return "—"
        const units = ["B", "KB", "MB", "GB", "TB"]
        let value = bytes, i = 0
        while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
        return (value >= 10 || i === 0 ? Math.round(value) : value.toFixed(1)) + " " + units[i]
    }

    function humanRate(bytesPerSecond) {
        if (bytesPerSecond === null || bytesPerSecond === undefined) return "—"
        return root.humanBytes(bytesPerSecond) + "/s"
    }

    // --- NETWORKMANAGER ---
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wifiDevice: devices.find(d => d.type === DeviceType.Wifi) || null
    readonly property var wiredDevices: devices.filter(d => d.type === DeviceType.Wired)

    // Connected first, then by signal. NetworkManager hands these back in
    // whatever order it discovered them, which is useless to read.
    readonly property var wifiNetworks: {
        if (!wifiDevice || !wifiDevice.networks) return []
        const list = wifiDevice.networks.values.slice()
        list.sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1
            return (b.signalStrength || 0) - (a.signalStrength || 0)
        })
        return list
    }

    // Which network currently has the inline password field open, if any.
    property var pskFor: null
    property string pskText: ""

    function secured(net) {
        return net && net.security !== WifiSecurityType.Open
                   && net.security !== WifiSecurityType.Owe
    }

    // signalStrength is 0..1. Material has no partial-wifi ligature set worth
    // using, so step the same glyph through four opacity bands instead.
    function bars(strength) {
        const s = strength || 0
        if (s > 0.75) return 4
        if (s > 0.5) return 3
        if (s > 0.25) return 2
        return 1
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

    // A label/value line in the detail blocks. Hides itself when the value is
    // missing, so a machine without (say) a gateway simply shows one row fewer
    // rather than an empty field.
    component DetailRow: RowLayout {
        required property string label
        property string value: ""

        Layout.fillWidth: true
        spacing: Tokens.space.md
        visible: value !== "" && value !== "undefined" && value !== "null"

        Text {
            text: parent.label
            font.family: Theme.fontFamily
            font.pixelSize: 11
            color: Theme.outline
            Layout.preferredWidth: 76
            leftPadding: Tokens.space.md
        }

        Text {
            Layout.fillWidth: true
            text: parent.value
            font.family: Theme.fontFamily
            font.pixelSize: 11
            color: Theme.on_surface
            elide: Text.ElideRight
        }
    }

    // A throughput line: icon, direction, current rate, and a muted
    // total/peak clause underneath - the same "value now, provenance
    // underneath" shape DetailRow uses, with a bigger trailing number because
    // this is the thing this section exists to show.
    component ThroughputRow: RowLayout {
        id: trow
        required property string glyph
        required property string label
        property string value: "—"
        property string note: ""

        Layout.fillWidth: true
        spacing: PanelStyle.panelSpacing

        Glyph {
            text: trow.glyph
            font.pixelSize: 18
            leftPadding: Tokens.space.md
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.space.none

            Text {
                text: trow.label
                font.family: Theme.fontFamily
                font.pixelSize: 11
                color: Theme.outline
            }

            Text {
                visible: trow.note !== ""
                text: trow.note
                font.family: Theme.fontFamily
                font.pixelSize: 10
                color: Theme.outline
            }
        }

        Text {
            text: trow.value
            font.family: Theme.fontFamily
            font.pixelSize: 13
            font.bold: true
            color: Theme.on_surface
        }
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
            border.width: PanelStyle.panelBorderWidth
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
                spacing: PanelStyle.panelSpacing

                Text {
                    Layout.fillWidth: true
                    text: "Network"
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                    font.bold: true
                    color: Theme.primary
                }

                Toggle {
                    checked: Networking.wifiEnabled
                    enabled: Networking.wifiHardwareEnabled
                    onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
                }

                Rectangle {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: PanelStyle.buttonRadius
                    color: settingsMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"

                    ToolTip.visible: settingsMouse.containsMouse
                    ToolTip.text: "Open nm-connection-editor"
                    ToolTip.delay: 400

                    Glyph { anchors.centerIn: parent; text: "tune"; font.pixelSize: 17 }

                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["nm-connection-editor"])
                            root.isOpen = false
                        }
                    }
                }
            }

            Divider {}

            // --- THROUGHPUT ---
            RowLayout {
                Layout.fillWidth: true

                SectionLabel { Layout.fillWidth: true; text: "Throughput" }

                // The picker: current selection + a caret, expanding the
                // option list below on click. A real dropdown rather than a
                // row of chips - there's a "total" entry as well as one per
                // interface, and that can grow past what a chip row reads
                // well at (a machine with wifi, ethernet AND a VPN up).
                Rectangle {
                    id: ifacePicker
                    implicitHeight: 22
                    implicitWidth: pickerRow.implicitWidth + 16
                    radius: PanelStyle.chipRadius
                    color: pickerMouse.containsMouse || root.ifaceMenuOpen
                           ? PanelStyle.fillHover : PanelStyle.fillSubtle

                    RowLayout {
                        id: pickerRow
                        anchors.centerIn: parent
                        spacing: 2

                        Text {
                            text: root.selectedIface === "" ? "Auto"
                                : root.selectedIface === "total" ? "Total"
                                : root.selectedIface
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            color: Theme.on_surface
                        }

                        Glyph {
                            text: root.ifaceMenuOpen ? "expand_less" : "expand_more"
                            font.pixelSize: 12
                        }
                    }

                    MouseArea {
                        id: pickerMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.ifaceMenuOpen = !root.ifaceMenuOpen
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.hairline
                visible: root.ifaceMenuOpen

                Repeater {
                    // "Auto" first (follows the default route), then every
                    // interface the backend is currently reading, then the
                    // combined total last.
                    model: [""].concat(root.throughput.interfaces || []).concat(["total"])

                    Rectangle {
                        id: ifaceOption
                        required property string modelData
                        readonly property bool current: modelData === root.selectedIface

                        Layout.fillWidth: true
                        implicitHeight: 22
                        radius: PanelStyle.controlRadius
                        color: optMouse.containsMouse ? PanelStyle.fillHover : "transparent"

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: Tokens.space.md
                            text: ifaceOption.modelData === "" ? "Auto (default route)"
                                : ifaceOption.modelData === "total" ? "Total (all interfaces)"
                                : ifaceOption.modelData
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                            color: ifaceOption.current ? Theme.primary : Theme.on_surface
                        }

                        MouseArea {
                            id: optMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.selectedIface = ifaceOption.modelData
                                root.ifaceMenuOpen = false
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs

                ThroughputRow {
                    glyph: "download"
                    label: "Down"
                    value: root.humanRate(root.throughputEntry.rx_rate)
                    note: "Total " + root.humanBytes(root.throughputEntry.rx_total)
                          + "  ·  Top " + root.humanRate(root.throughputEntry.top_rx)
                }

                ThroughputRow {
                    glyph: "upload"
                    label: "Up"
                    value: root.humanRate(root.throughputEntry.tx_rate)
                    note: "Total " + root.humanBytes(root.throughputEntry.tx_total)
                          + "  ·  Top " + root.humanRate(root.throughputEntry.top_tx)
                }

                // Both series autoscale independently (Sparkline's default),
                // which is the right call here: sharing one scale would let a
                // single big download burst flatten the upload trace to
                // nothing, and this is a "is it moving" glance, not a graph
                // anyone is reading absolute values off.
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    Layout.topMargin: Tokens.space.xs
                    Layout.leftMargin: Tokens.space.md
                    Layout.rightMargin: Tokens.space.md

                    Sparkline {
                        anchors.fill: parent
                        samples: root.throughputEntry.history ? root.throughputEntry.history.rx : []
                        lineColor: Theme.primary
                    }

                    Sparkline {
                        anchors.fill: parent
                        samples: root.throughputEntry.history ? root.throughputEntry.history.tx : []
                        lineColor: Theme.tertiary
                    }
                }
            }

            Divider {}

            // --- WIRED ---
            SectionLabel {
                text: "Wired"
                visible: root.wiredDevices.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.wiredDevices.length > 0

                Repeater {
                    model: root.wiredDevices

                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: PanelStyle.panelSpacing

                        Glyph {
                            text: "lan"
                            font.pixelSize: 18
                            color: modelData.connected ? Theme.primary : Theme.outline
                            leftPadding: Tokens.space.md
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.space.none

                            Text {
                                text: modelData.name
                                font.family: Theme.fontFamily
                                font.pixelSize: 12
                                color: modelData.connected ? Theme.primary : Theme.on_surface
                            }

                            Text {
                                text: modelData.connected ? (modelData.address || "Connected") : "Disconnected"
                                font.family: Theme.fontFamily
                                font.pixelSize: 10
                                color: Theme.outline
                            }
                        }
                    }
                }
            }

            Divider { visible: root.wiredDevices.length > 0 && root.wifiDevice }

            // --- WI-FI ---
            RowLayout {
                Layout.fillWidth: true
                visible: root.wifiDevice !== null

                SectionLabel { Layout.fillWidth: true; text: "Wi-Fi" }

                Text {
                    text: "Rescan"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: rescan.containsMouse ? Theme.primary : Theme.outline
                    visible: Networking.wifiEnabled

                    ToolTip.visible: rescan.containsMouse
                    ToolTip.text: "Scan again for nearby networks"
                    ToolTip.delay: 400

                    MouseArea {
                        id: rescan
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Toggling the scanner is what forces a fresh sweep.
                            root.wifiDevice.scannerEnabled = false
                            root.wifiDevice.scannerEnabled = true
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.wifiDevice !== null && !Networking.wifiEnabled
                text: Networking.wifiHardwareEnabled ? "Wi-Fi is off" : "Wi-Fi is blocked by hardware"
                font.family: Theme.fontFamily
                font.pixelSize: 12
                color: Theme.outline
                leftPadding: Tokens.space.md
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.wifiDevice !== null && Networking.wifiEnabled

                Repeater {
                    model: root.wifiNetworks

                    ColumnLayout {
                        id: netEntry
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Tokens.space.none

                        readonly property bool pskOpen: root.pskFor === modelData

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 36
                            radius: PanelStyle.buttonRadius
                            color: netMouse.containsMouse
                                   ? PanelStyle.fillHover
                                   : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Tokens.space.md
                                anchors.rightMargin: Tokens.space.md
                                spacing: PanelStyle.panelSpacing

                                Glyph {
                                    text: "wifi"
                                    font.pixelSize: 18
                                    color: netEntry.modelData.connected ? Theme.primary : Theme.on_surface
                                    // 4 bars -> full strength, 1 bar -> faint.
                                    opacity: 0.25 + 0.25 * root.bars(netEntry.modelData.signalStrength)
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: netEntry.modelData.name || "(hidden)"
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    color: netEntry.modelData.connected ? Theme.primary : Theme.on_surface
                                    elide: Text.ElideRight
                                }

                                Text {
                                    visible: netEntry.modelData.stateChanging
                                    text: "…"
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    color: Theme.outline
                                }

                                Glyph {
                                    text: "lock"
                                    font.pixelSize: 13
                                    color: Theme.outline
                                    visible: root.secured(netEntry.modelData)
                                }

                                Glyph {
                                    text: "close"
                                    font.pixelSize: 14
                                    color: forget.containsMouse ? Theme.error : Theme.outline
                                    visible: netEntry.modelData.known

                                    MouseArea {
                                        id: forget
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: netEntry.modelData.forget()
                                    }
                                }
                            }

                            MouseArea {
                                id: netMouse
                                anchors.fill: parent
                                anchors.rightMargin: Tokens.space.gutter
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const net = netEntry.modelData
                                    if (net.connected) {
                                        net.disconnect()
                                    } else if (net.known || !root.secured(net)) {
                                        // A known network already has its
                                        // credentials in NetworkManager.
                                        net.connect()
                                    } else {
                                        root.pskText = ""
                                        root.pskFor = netEntry.pskOpen ? null : net
                                    }
                                }
                            }
                        }

                        // Inline password entry, shown only for a secured
                        // network NetworkManager has no saved secret for.
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.leftMargin: Tokens.space.md
                            Layout.rightMargin: Tokens.space.md
                            Layout.topMargin: Tokens.space.xs
                            Layout.bottomMargin: Tokens.space.xs
                            implicitHeight: netEntry.pskOpen ? 32 : 0
                            visible: netEntry.pskOpen
                            radius: PanelStyle.buttonRadius
                            color: PanelStyle.fillSubtle

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Tokens.space.md
                                anchors.rightMargin: Tokens.space.sm
                                spacing: Tokens.space.sm

                                TextInput {
                                    id: pskField
                                    Layout.fillWidth: true
                                    text: root.pskText
                                    onTextChanged: root.pskText = text
                                    echoMode: TextInput.Password
                                    font.family: Theme.fontFamily
                                    font.pixelSize: 12
                                    color: Theme.on_surface
                                    clip: true
                                    verticalAlignment: TextInput.AlignVCenter
                                    focus: netEntry.pskOpen
                                    onAccepted: {
                                        netEntry.modelData.connectWithPsk(root.pskText)
                                        root.pskFor = null
                                        root.pskText = ""
                                    }

                                    Text {
                                        anchors.fill: parent
                                        visible: pskField.text === ""
                                        text: "Password"
                                        font: pskField.font
                                        color: Theme.outline
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                }

                                Glyph {
                                    text: "arrow_forward"
                                    font.pixelSize: 16

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            netEntry.modelData.connectWithPsk(root.pskText)
                                            root.pskFor = null
                                            root.pskText = ""
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.wifiDevice !== null && Networking.wifiEnabled && root.wifiNetworks.length === 0
                text: "Scanning…"
                font.family: Theme.fontFamily
                font.pixelSize: 11
                color: Theme.outline
                leftPadding: Tokens.space.md
            }

            // --- CONNECTION DETAILS ---
            // The same facts the bar module's hover tooltip used to carry, which
            // was the only place they lived once the module started opening this
            // panel instead of showing a tooltip.
            Divider { visible: root.details.wifi !== undefined && root.details.wifi !== null }

            SectionLabel {
                text: "Connection"
                visible: root.details.wifi !== undefined && root.details.wifi !== null
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                visible: root.details.wifi !== undefined && root.details.wifi !== null

                DetailRow { label: "Network"; value: root.details.wifi ? (root.details.wifi.ssid || "") : "" }
                DetailRow { label: "Interface"; value: root.details.wifi ? (root.details.wifi.interface || "") : "" }
                DetailRow { label: "IP"; value: root.details.wifi ? (root.details.wifi.address || "") : "" }
                DetailRow { label: "Gateway"; value: root.details.wifi ? (root.details.wifi.gateway || "") : "" }
                DetailRow { label: "DNS"; value: root.details.wifi ? (root.details.wifi.dns || "") : "" }
                DetailRow {
                    label: "Signal"
                    value: root.details.wifi && root.details.wifi.signal !== null
                           ? root.details.wifi.signal + "%" : ""
                }
                DetailRow { label: "Link rate"; value: root.details.wifi ? (root.details.wifi.rate || "") : "" }
                DetailRow { label: "Frequency"; value: root.details.wifi ? (root.details.wifi.frequency || "") : "" }
                DetailRow { label: "Security"; value: root.details.wifi ? (root.details.wifi.security || "") : "" }
            }

            // --- TAILSCALE ---
            // Not a NetworkManager device, so none of the machinery above sees
            // it; this block is driven entirely by `tailscale status --json`.
            Divider { visible: root.details.tailscale !== undefined && root.details.tailscale !== null }

            RowLayout {
                Layout.fillWidth: true
                visible: root.details.tailscale !== undefined && root.details.tailscale !== null
                spacing: PanelStyle.panelSpacing

                SectionLabel { Layout.fillWidth: true; text: "Tailscale" }

                Text {
                    readonly property bool up: root.details.tailscale
                                               && root.details.tailscale.state === "Running"
                    text: up ? "Disconnect" : "Connect"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: tsMouse.containsMouse ? Theme.primary : Theme.outline

                    ToolTip.visible: tsMouse.containsMouse
                    ToolTip.text: "Bring the Tailscale connection up or down"
                    ToolTip.delay: 400

                    MouseArea {
                        id: tsMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(
                                ["tailscale", parent.up ? "down" : "up"])
                            // Give the daemon a moment before re-reading, or the
                            // panel shows the state we just left.
                            tsRecheck.restart()
                        }
                    }
                }
            }

            Timer {
                id: tsRecheck
                interval: 1200
                repeat: false
                onTriggered: if (!detailsProc.running) detailsProc.running = true
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                visible: root.details.tailscale !== undefined && root.details.tailscale !== null

                DetailRow {
                    label: "Status"
                    value: {
                        const ts = root.details.tailscale
                        if (!ts) return ""
                        if (ts.state !== "Running") return ts.state || "Stopped"
                        return ts.online ? "Connected" : "Running (offline)"
                    }
                }
                DetailRow { label: "Machine"; value: root.details.tailscale ? (root.details.tailscale.hostname || "") : "" }
                DetailRow { label: "IP"; value: root.details.tailscale ? (root.details.tailscale.ip || "") : "" }
                DetailRow { label: "Tailnet"; value: root.details.tailscale ? (root.details.tailscale.tailnet || "") : "" }
                DetailRow { label: "MagicDNS"; value: root.details.tailscale ? (root.details.tailscale.magic_dns || "") : "" }
                DetailRow { label: "Exit node"; value: root.details.tailscale ? (root.details.tailscale.exit_node || "") : "" }
                DetailRow {
                    label: "Peers"
                    value: root.details.tailscale && root.details.tailscale.peers_total !== undefined
                           ? root.details.tailscale.peers_online + " of "
                             + root.details.tailscale.peers_total + " online"
                           : ""
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
