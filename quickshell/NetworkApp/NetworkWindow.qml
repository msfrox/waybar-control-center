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
    // A flat 900 (this file's original cap) overflows a real screen once
    // enough sections are open at once - Shehan, 2026-09-05: "the details
    // are still overflowing below the window." AudioWindow.qml already
    // caps against the actual screen instead; this matches that pattern.
    implicitHeight: Math.min(content.implicitHeight + 80,
                             (screen ? screen.height : 1080) - 140)
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
            // The rate graph's own history is NOT reset here - it lives in
            // the daemon's published ring buffer (`liveRateFile`), not in
            // this popup, precisely so it keeps covering the last 5 minutes
            // across a close/reopen instead of going blank. Only this
            // popup's own local UI state (the connections list fetch) is
            // session-scoped.
            connectionsOpen = false
            root.connections = []
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
    // Backed by `brilliant-network`, not network-throughput.py (deleted -
    // B7 step 2, 2026-09-05): that script and this daemon's own `rate`
    // subcommand were "two front ends, one feature" (measurement vs.
    // presentation).
    //
    // 🔴 Not a `rate` Process on a timer, either - that was this file's own
    // first draft this session, and Shehan caught the flaw immediately:
    // "it only updates or works when the panel is open... so its basically
    // useless as is [...] it should show last 5 minutes usage there." A
    // Process the popup itself starts cannot show history from before the
    // popup existed. So the daemon now publishes a rolling 5-minute ring
    // buffer continuously, popup open or not (`live_publish.rs`,
    // `~/Projects/brilliant-daemons`) - the exact "bounded ring buffer"
    // fix this batch's own spec already named as the escape hatch. This
    // panel just reads that file, the same watched-FileView pattern
    // `tokens.json` and `brilliant.json` already use elsewhere in this
    // codebase: no polling, no Process, pushed the instant the daemon
    // writes. Opening the popup after five minutes away shows a full
    // graph on the very first frame, because the buffer was never empty.
    readonly property string liveRatePath: {
        const xdg = Quickshell.env("XDG_DATA_HOME")
        const base = (xdg && xdg !== "") ? xdg : (Quickshell.env("HOME") + "/.local/share")
        return base + "/brilliant/network-live.json"
    }

    property var liveSamples: []  // oldest first; each {at, rates: [{name, kind, rx_bytes_per_second, tx_bytes_per_second, default_route}]}

    FileView {
        id: liveRateFile
        path: root.liveRatePath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const parsed = JSON.parse(liveRateFile.text())
                root.liveSamples = Array.isArray(parsed.samples) ? parsed.samples : []
            } catch (e) {
                root.liveSamples = []
            }
        }
        // Nothing collected yet (daemon just installed, or its very first
        // tick hasn't landed) is the normal first-run case, not an error -
        // same contract `network-usage.json` documents.
        onLoadFailed: (error) => root.liveSamples = []
    }

    // One rx/tx pair per sample, oldest first, for `name` - "total" sums
    // every interface in that sample. An interface absent from a given
    // sample (came up mid-window) reads as 0 for it, not a gap, so the
    // series stays one point per sample.
    function rateSeriesFor(name) {
        const rx = [], tx = []
        for (const sample of root.liveSamples) {
            if (name === "total") {
                let r = 0, t = 0
                for (const e of sample.rates) { r += e.rx_bytes_per_second; t += e.tx_bytes_per_second }
                rx.push(r); tx.push(t)
            } else {
                const hit = sample.rates.find(e => e.name === name)
                rx.push(hit ? hit.rx_bytes_per_second : 0)
                tx.push(hit ? hit.tx_bytes_per_second : 0)
            }
        }
        return { rx, tx }
    }

    property var ifaceLifetimes: ({})  // name -> {rx_bytes, tx_bytes}, from `interfaces` - cumulative "Total" needs a running counter a rate sample doesn't carry.

    // --- DATA USAGE state (properties only - the Process/Timer/UI live
    // with the section below, but `onXChanged` handlers and cross-item
    // bindings need these declared where `root.` actually resolves them) ---
    property int usagePeriodDays: 30
    property var usageData: ({})
    readonly property var usageDays: {
        const days = root.usageData.days || {}
        return Object.keys(days).sort()
    }
    readonly property var usageSeries: {
        const days = root.usageData.days || {}
        return root.usageDays.map(d => days[d].rx + days[d].tx)
    }
    // Re-fetch immediately when the period changes rather than waiting for
    // the next 60s tick (`usageProc`/its Timer are declared with the
    // Data usage section below; the id is visible document-wide).
    onUsagePeriodDaysChanged: if (root.isOpen && !usageProc.running) usageProc.running = true

    // --- CONNECTIONS state ---
    property bool connectionsOpen: false
    property var connections: []

    // Both collapsed by default, same reasoning as Connections above -
    // Shehan, 2026-09-05, after the panel overflowed the screen once every
    // section this batch touched was expanded at once: "make the connection
    // info and the tailscale sections collapseable."
    property bool connectionDetailsOpen: false
    property bool tailscaleDetailsOpen: false

    Process {
        id: interfacesProc
        command: [Quickshell.env("HOME") + "/.local/bin/brilliant-network", "interfaces"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const list = JSON.parse(this.text)
                    const map = {}
                    for (const i of list) map[i.name] = i
                    root.ifaceLifetimes = map
                } catch (e) {
                    root.ifaceLifetimes = {}
                }
            }
        }
    }

    // Shares the details poll's 5s cadence - link state and lifetime
    // counters don't need the rate ring buffer's 2s freshness.
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: root.isOpen
        onTriggered: if (!interfacesProc.running) interfacesProc.running = true
    }

    // "" means auto: follow whichever interface the latest sample marks
    // default_route, rather than pinning to whatever that happened to be on
    // first read, so it keeps tracking correctly through a wifi/ethernet
    // handover. Picking an explicit interface (or "total") below overrides it.
    property string selectedIface: ""
    property bool ifaceMenuOpen: false

    // The interfaces the ring buffer currently knows about - the latest
    // sample's own list, so a picker built from this never offers an
    // interface that vanished five minutes ago.
    readonly property var liveIfaceNames: {
        if (root.liveSamples.length === 0) return []
        return root.liveSamples[root.liveSamples.length - 1].rates.map(e => e.name)
    }

    readonly property string autoIfaceName: {
        if (root.liveSamples.length === 0) return ""
        const latest = root.liveSamples[root.liveSamples.length - 1]
        const hit = latest.rates.find(e => e.default_route)
        return hit ? hit.name : ""
    }

    readonly property string effectiveIface: root.selectedIface !== "" ? root.selectedIface
        : (root.autoIfaceName !== "" ? root.autoIfaceName : "total")

    readonly property var throughputEntry: {
        const key = root.effectiveIface
        const series = root.rateSeriesFor(key)
        const rxRate = series.rx.length > 0 ? series.rx[series.rx.length - 1] : 0
        const txRate = series.tx.length > 0 ? series.tx[series.tx.length - 1] : 0
        const topRx = series.rx.reduce((m, v) => Math.max(m, v), 0)
        const topTx = series.tx.reduce((m, v) => Math.max(m, v), 0)

        let rxTotal = null, txTotal = null
        if (key === "total") {
            let rxSum = 0, txSum = 0, any = false
            for (const name in root.ifaceLifetimes) {
                rxSum += root.ifaceLifetimes[name].rx_bytes
                txSum += root.ifaceLifetimes[name].tx_bytes
                any = true
            }
            if (any) { rxTotal = rxSum; txTotal = txSum }
        } else {
            const life = root.ifaceLifetimes[key]
            if (life) { rxTotal = life.rx_bytes; txTotal = life.tx_bytes }
        }

        return {
            rx_rate: rxRate, tx_rate: txRate,
            rx_total: rxTotal, tx_total: txTotal,
            top_rx: topRx, top_tx: topTx,
            history: { rx: series.rx, tx: series.tx },
        }
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
    // Two of these sit side by side (Down/Up, Downloaded/Uploaded) rather
    // than stacking as full-width rows - Shehan's call, 2026-09-05, after
    // the first draft's row-per-stat layout ran the popup taller than the
    // screen: "format that so its two boxes next to each other not a list."
    component StatBox: ColumnLayout {
        id: box
        required property string glyph
        required property string label
        property string value: "—"
        property string note: ""

        Layout.fillWidth: true
        Layout.leftMargin: Tokens.space.md
        spacing: Tokens.space.none

        RowLayout {
            spacing: Tokens.space.xs

            Glyph { text: box.glyph; font.pixelSize: 15 }

            Text {
                text: box.label
                font.family: Theme.fontFamily
                font.pixelSize: 11
                color: Theme.outline
            }
        }

        Text {
            text: box.value
            font.family: Theme.fontFamily
            font.pixelSize: 15
            font.bold: true
            color: Theme.on_surface
        }

        Text {
            Layout.fillWidth: true
            visible: box.note !== ""
            text: box.note
            font.family: Theme.fontFamily
            font.pixelSize: 9
            color: Theme.outline
            wrapMode: Text.Wrap
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
                    ToolTip.text: "Open Network in Settings"
                    ToolTip.delay: 400

                    Glyph { anchors.centerIn: parent; text: "tune"; font.pixelSize: 17 }

                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Was nm-connection-editor - Shehan, 2026-09-05:
                            // "reroute that setting icon to our settings
                            // app." hyprsys's own Network page (this
                            // batch's other half) is the real destination
                            // now; nm-connection-editor is still reachable
                            // from there as that page's own delegation
                            // fallback if it's ever needed.
                            Quickshell.execDetached(["hyprsys", "--page", "network"])
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
                    model: [""].concat(root.liveIfaceNames).concat(["total"])

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

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PanelStyle.panelSpacing

                    StatBox {
                        glyph: "download"
                        label: "Down"
                        value: root.humanRate(root.throughputEntry.rx_rate)
                        note: "Total " + root.humanBytes(root.throughputEntry.rx_total)
                              + " · Top " + root.humanRate(root.throughputEntry.top_rx)
                    }

                    StatBox {
                        glyph: "upload"
                        label: "Up"
                        value: root.humanRate(root.throughputEntry.tx_rate)
                        note: "Total " + root.humanBytes(root.throughputEntry.tx_total)
                              + " · Top " + root.humanRate(root.throughputEntry.top_tx)
                    }
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

            // --- DATA USAGE ---
            //
            // The popup's throughput block used to be annotated "(no
            // history)" - this is the history, and the reason
            // `brilliant-network` exists at all (§B7 step 1): kernel
            // counters reset every reboot, so a persistent collector was
            // the only way to answer "how much have I used this month."
            // `total_physical` (wired + wireless only) is what's shown here,
            // not a sum across every interface - tunnel traffic rides over
            // the physical NIC it tunnels through, so summing double-counts
            // every VPN byte (the exact bug `network-throughput.py`'s old
            // "total" had, per [[26-path-to-v1]] §B7). The full arbitrary
            // date-range filter is the settings page's job, not this
            // popup's - this shows the common cases at a glance.
            Process {
                id: usageProc
                command: [Quickshell.env("HOME") + "/.local/bin/brilliant-network",
                          "usage", "--days", String(root.usagePeriodDays)]
                stdout: StdioCollector {
                    onStreamFinished: {
                        try {
                            root.usageData = JSON.parse(this.text)
                        } catch (e) {
                            root.usageData = {}
                        }
                    }
                }
            }

            // Usage history doesn't need the rate tick's freshness - once on
            // open, and a slow re-check in case the popup is left open
            // across midnight.
            Timer {
                interval: 60000
                repeat: true
                triggeredOnStart: true
                running: root.isOpen
                onTriggered: if (!usageProc.running) usageProc.running = true
            }

            RowLayout {
                Layout.fillWidth: true

                SectionLabel { Layout.fillWidth: true; text: "Data usage" }

                Repeater {
                    model: [1, 7, 30]

                    Rectangle {
                        id: periodChip
                        required property int modelData
                        readonly property bool current: modelData === root.usagePeriodDays

                        implicitHeight: 20
                        implicitWidth: periodLabel.implicitWidth + 14
                        radius: PanelStyle.chipRadius
                        color: current ? PanelStyle.fillHover
                             : periodMouse.containsMouse ? PanelStyle.fillSubtle : "transparent"

                        Text {
                            id: periodLabel
                            anchors.centerIn: parent
                            text: periodChip.modelData + "d"
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            color: periodChip.current ? Theme.primary : Theme.outline
                        }

                        MouseArea {
                            id: periodMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.usagePeriodDays = periodChip.modelData
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PanelStyle.panelSpacing

                    StatBox {
                        glyph: "south"
                        label: "Downloaded"
                        value: root.humanBytes(root.usageData.total_physical ? root.usageData.total_physical.rx : null)
                        note: "Last " + root.usagePeriodDays + " days · wired + wireless"
                    }

                    StatBox {
                        glyph: "north"
                        label: "Uploaded"
                        value: root.humanBytes(root.usageData.total_physical ? root.usageData.total_physical.tx : null)
                        note: "Last " + root.usagePeriodDays + " days · wired + wireless"
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    Layout.topMargin: Tokens.space.xs
                    Layout.leftMargin: Tokens.space.md
                    Layout.rightMargin: Tokens.space.md
                    visible: root.usageSeries.length > 1

                    Sparkline {
                        anchors.fill: parent
                        samples: root.usageSeries
                        lineColor: Theme.secondary
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: Tokens.space.md
                    visible: root.usageDays.length > 0
                    text: "Daily total, oldest → newest, " + root.usageDays.length + " day"
                          + (root.usageDays.length === 1 ? "" : "s") + " recorded"
                    font.family: Theme.fontFamily
                    font.pixelSize: 9
                    color: Theme.outline
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

            RowLayout {
                Layout.fillWidth: true
                visible: root.details.wifi !== undefined && root.details.wifi !== null
                spacing: PanelStyle.panelSpacing

                SectionLabel { Layout.fillWidth: true; text: "Connection" }

                Text {
                    text: root.connectionDetailsOpen ? "Hide" : "Show"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: connDetailsToggle.containsMouse ? Theme.primary : Theme.outline

                    MouseArea {
                        id: connDetailsToggle
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.connectionDetailsOpen = !root.connectionDetailsOpen
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3
                visible: root.connectionDetailsOpen
                         && root.details.wifi !== undefined && root.details.wifi !== null

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

                Text {
                    text: root.tailscaleDetailsOpen ? "Hide" : "Show"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: tsDetailsToggle.containsMouse ? Theme.primary : Theme.outline

                    MouseArea {
                        id: tsDetailsToggle
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.tailscaleDetailsOpen = !root.tailscaleDetailsOpen
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
                visible: root.tailscaleDetailsOpen
                         && root.details.tailscale !== undefined && root.details.tailscale !== null

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
                // VPN status, the original B7 spec line: `interfaces` already
                // reports kind:"tunnel" with link state - that's the read
                // behind this row, so it's real information (does the
                // tunnel's own network interface have a carrier right now),
                // not a duplicate of the "Status"/"online" row above (which
                // comes from `tailscale status`, a different fact).
                DetailRow {
                    label: "Link"
                    value: {
                        const tun = Object.values(root.ifaceLifetimes).find(i => i.kind === "tunnel")
                        if (!tun) return ""
                        return tun.carrier ? "Up (" + tun.operstate + ")" : "No carrier"
                    }
                }
            }

            // --- CONNECTIONS ---
            // New surface capability, [[26-path-to-v1]] §B7 step 2 item 4:
            // what this machine is talking to right now. Collapsed by
            // default and only polled while expanded - process attribution
            // walks /proc/*/fd per socket, which is not something to spend
            // on a section nobody is looking at.
            Divider {}

            RowLayout {
                Layout.fillWidth: true

                SectionLabel { Layout.fillWidth: true; text: "Connections" }

                Text {
                    text: root.connectionsOpen ? "Hide" : "Show"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: connToggle.containsMouse ? Theme.primary : Theme.outline

                    MouseArea {
                        id: connToggle
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.connectionsOpen = !root.connectionsOpen
                    }
                }
            }

            Process {
                id: connectionsProc
                command: [Quickshell.env("HOME") + "/.local/bin/brilliant-network", "connections", "--established"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        try {
                            root.connections = JSON.parse(this.text)
                        } catch (e) {
                            root.connections = []
                        }
                    }
                }
            }

            Timer {
                interval: 5000
                repeat: true
                triggeredOnStart: true
                running: root.isOpen && root.connectionsOpen
                onTriggered: if (!connectionsProc.running) connectionsProc.running = true
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.hairline
                visible: root.connectionsOpen

                Repeater {
                    // Capped at 12 - this is a glance, not a netstat replacement.
                    model: root.connections.slice(0, 12)

                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: Tokens.space.md
                        Layout.rightMargin: Tokens.space.md
                        spacing: Tokens.space.sm

                        Text {
                            Layout.preferredWidth: 90
                            // A socket owned by another user shows no PID -
                            // "unknown", per ADR-0014 §5, never an error.
                            text: modelData.process || "unknown"
                            font.family: Theme.fontFamily
                            font.pixelSize: 11
                            color: Theme.on_surface
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            text: modelData.remote_address + ":" + modelData.remote_port
                            font.family: Theme.fontFamily
                            font.pixelSize: 10
                            color: Theme.outline
                            elide: Text.ElideRight
                        }
                    }
                }

                Text {
                    visible: root.connections.length > 12
                    Layout.leftMargin: Tokens.space.md
                    text: (root.connections.length - 12) + " more…"
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    color: Theme.outline
                }

                Text {
                    visible: root.connectionsOpen && root.connections.length === 0
                    Layout.leftMargin: Tokens.space.md
                    text: "No established connections"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: Theme.outline
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
