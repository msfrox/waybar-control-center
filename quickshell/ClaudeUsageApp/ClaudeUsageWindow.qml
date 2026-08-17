// Claude Code usage popup for the bar's usage dial.
//
// The bar module is a dial and a hover label, which is about as much as it can
// be. This is where the numbers get read properly and where the display options
// live - a port of the option set the COSMIC YapCap applet exposes, which is
// what prompted it.
//
// It owns no data of its own. claude-usage.py is the single thing that talks to
// the usage endpoint; it caches its reading to
//   ~/.cache/hyprbar/claude-usage-state.json
// which this reads, and it owns the settings file
//   ~/.config/hyprbar/claude-usage.json
// which this writes through `claude-usage.py --set key=value`. Two processes
// hand-editing the same JSON would be a race for no benefit.
//
// Window chrome is duplicated from AudioWindow on purpose; see the note at the
// top of BluetoothWindow.qml.

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import qs.CustomTheme

PanelWindow {
    id: root

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: WlrLayershell.Ignore

    implicitWidth: 440
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

    onIsOpenChanged: if (isOpen) { showWindow = true; reload() }

    Behavior on currentBottomMargin {
        NumberAnimation {
            duration: 350
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
        target: "claude-usage"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- DATA ---
    readonly property string script: Quickshell.env("HOME") + "/.config/brilliant/providers/claude-usage.py"
    readonly property string statePath: Quickshell.env("HOME") + "/.cache/hyprbar/claude-usage-state.json"
    readonly property string settingsPath: Quickshell.env("HOME") + "/.config/hyprbar/claude-usage.json"

    property var state: ({})
    property var settings: ({
        usage_amount_format: "used",
        reset_time_format: "relative",
        refresh_interval_seconds: 300,
        show_percent: false
    })
    property bool refreshing: false

    function reload() {
        stateProc.running = false; stateProc.running = true
        settingsProc.running = false; settingsProc.running = true
    }

    // `cat` rather than a file watcher: these are read on open and after an
    // explicit action, never continuously, so a watcher would be more moving
    // parts for nothing. Same approach ML4W's own Theme.qml uses.
    Process {
        id: stateProc
        command: ["cat", root.statePath]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.state = JSON.parse(this.text) } catch (e) { root.state = {} }
            }
        }
    }

    Process {
        id: settingsProc
        command: ["cat", root.settingsPath]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(this.text)
                    // Merge rather than replace - the file only carries keys
                    // that have been changed from their default.
                    const merged = {}
                    for (const k in root.settings) merged[k] = root.settings[k]
                    for (const k in parsed) merged[k] = parsed[k]
                    root.settings = merged
                } catch (e) {
                    // No settings file yet: the defaults above are correct.
                }
            }
        }
    }

    // The script rewrites the state file, which the bar's dial is already
    // watching, so the bar and this panel never disagree about what is being
    // shown - no signal needed.
    Process {
        id: applyProc
        onExited: { root.refreshing = false; root.reload() }
    }

    function apply(pairs) {
        root.refreshing = true
        applyProc.command = ["bash", "-c",
            root.script + " --set " + pairs.join(" ") + " >/dev/null 2>&1"]
        applyProc.running = true
    }

    function refreshNow() {
        root.refreshing = true
        applyProc.command = ["bash", "-c",
            root.script + " --refresh >/dev/null 2>&1"]
        applyProc.running = true
    }

    // --- DERIVED ---
    function shown(pct) {
        return root.settings.usage_amount_format === "used" ? pct : 100 - pct
    }

    readonly property string amountWord: settings.usage_amount_format === "used" ? "used" : "left"

    function resetText(iso) {
        if (!iso) return ""
        const when = new Date(iso)
        if (root.settings.reset_time_format === "absolute") {
            return Qt.formatDateTime(when, "ddd HH:mm")
        }
        let secs = Math.max(0, (when.getTime() - Date.now()) / 1000)
        const days = Math.floor(secs / 86400); secs -= days * 86400
        const hours = Math.floor(secs / 3600); secs -= hours * 3600
        const mins = Math.floor(secs / 60)
        if (days > 0) return "in " + days + "d " + hours + "h"
        if (hours > 0) return "in " + hours + "h " + mins + "m"
        return "in " + mins + "m"
    }

    function levelColor(pct) {
        if (pct >= 90) return Theme.error
        if (pct >= 70) return Theme.tertiary
        return Theme.primary
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
        Layout.topMargin: 4
    }

    component Divider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.primary
        opacity: 0.3
    }

    // One usage window: name, percentage bar, reset countdown.
    component UsageBar: ColumnLayout {
        required property string title
        required property int pct
        required property string resets

        Layout.fillWidth: true
        spacing: 4

        RowLayout {
            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: parent.parent.title
                font.family: Theme.fontFamily
                font.pixelSize: 12
                color: Theme.on_surface
                leftPadding: 8
            }

            Text {
                text: root.shown(parent.parent.pct) + "% " + root.amountWord
                font.family: Theme.fontFamily
                font.pixelSize: 12
                font.bold: true
                color: root.levelColor(parent.parent.pct)
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            implicitHeight: 6
            radius: 3
            color: Qt.rgba(Theme.on_surface.r, Theme.on_surface.g, Theme.on_surface.b, 0.2)

            Rectangle {
                // Always the *used* fraction, whichever way the number above is
                // being phrased - a bar that empties as you consume quota reads
                // backwards.
                width: parent.width * Math.min(1, Math.max(0, parent.parent.pct / 100))
                height: parent.height
                radius: 3
                color: root.levelColor(parent.parent.pct)
                Behavior on width { NumberAnimation { duration: 250 } }
            }
        }

        Text {
            visible: text !== ""
            text: parent.resets ? "resets " + root.resetText(parent.resets) : ""
            font.family: Theme.fontFamily
            font.pixelSize: 10
            color: Theme.outline
            leftPadding: 8
        }
    }

    // A row of mutually exclusive pills - the shape every one of the display
    // options takes.
    component Segmented: RowLayout {
        id: seg
        required property string label
        required property var options   // [{ value, text }]
        required property string current
        signal picked(string value)

        Layout.fillWidth: true
        spacing: 8

        Text {
            text: seg.label
            font.family: Theme.fontFamily
            font.pixelSize: 11
            color: Theme.outline
            Layout.preferredWidth: 96
            leftPadding: 8
        }

        Repeater {
            model: seg.options

            Rectangle {
                required property var modelData
                readonly property bool selected: String(modelData.value) === seg.current

                implicitHeight: 24
                implicitWidth: pillText.implicitWidth + 20
                radius: 100
                color: selected ? Theme.primary
                                : pillMouse.containsMouse
                                  ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)
                                  : "transparent"
                border.width: selected ? 0 : 1
                border.color: Qt.rgba(Theme.on_surface.r, Theme.on_surface.g, Theme.on_surface.b, 0.25)

                Text {
                    id: pillText
                    anchors.centerIn: parent
                    text: parent.modelData.text
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: parent.selected ? Theme.on_primary : Theme.on_surface
                }

                MouseArea {
                    id: pillMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(String(parent.modelData.value))
                }
            }
        }

        Item { Layout.fillWidth: true }
    }

    // ==========================================
    // PANEL
    // ==========================================
    Item {
        anchors.fill: parent
        anchors.margins: 20

        RectangularShadow {
            anchors.fill: mainBgRect
            radius: mainBgRect.radius
            blur: 15
            color: Qt.rgba(Theme.shadow.r, Theme.shadow.g, Theme.shadow.b, 0.4)
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
            radius: 10
            color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.30)
            border.width: 1
            border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35)
        }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 20
            spacing: 10

            // --- HEADER ---
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    text: "Claude Code"
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                    font.bold: true
                    color: Theme.primary
                }

                Rectangle {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: 6
                    color: refreshMouse.containsMouse
                           ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
                           : "transparent"

                    ToolTip.visible: refreshMouse.containsMouse
                    ToolTip.text: "Fetch the usage figures again now"
                    ToolTip.delay: 400

                    Glyph {
                        anchors.centerIn: parent
                        text: "refresh"
                        font.pixelSize: 17
                        opacity: root.refreshing ? 0.4 : 1.0
                    }

                    MouseArea {
                        id: refreshMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !root.refreshing
                        onClicked: root.refreshNow()
                    }
                }
            }

            Divider {}

            // --- ERROR ---
            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 4
                visible: root.state.error !== undefined && root.state.error !== null

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Glyph {
                        text: "error_outline"
                        font.pixelSize: 16
                        color: Theme.error
                        leftPadding: 8
                    }

                    Text {
                        Layout.fillWidth: true
                        text: "Usage unavailable"
                        font.family: Theme.fontFamily
                        font.pixelSize: 12
                        color: Theme.error
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: root.state.error_hint || ""
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: Theme.on_surface
                    leftPadding: 8
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: root.state.error || ""
                    font.family: Theme.fontFamily
                    font.pixelSize: 10
                    color: Theme.outline
                    leftPadding: 8
                    wrapMode: Text.WordWrap
                }
            }

            // --- USAGE ---
            SectionLabel {
                text: "Usage"
                visible: !root.state.error
            }

            UsageBar {
                visible: !root.state.error
                title: "5-hour session"
                pct: root.state.block_pct || 0
                resets: root.state.block_resets_at || ""
            }

            UsageBar {
                visible: !root.state.error
                title: "7-day window"
                pct: root.state.week_pct || 0
                resets: root.state.week_resets_at || ""
            }

            Text {
                Layout.fillWidth: true
                visible: !root.state.error
                text: "The bar's dial shows the 7-day window as the ring and the session as the fill."
                font.family: Theme.fontFamily
                font.pixelSize: 10
                color: Theme.outline
                leftPadding: 8
                wrapMode: Text.WordWrap
            }

            Divider {}

            // --- DISPLAY OPTIONS ---
            SectionLabel { text: "Display" }

            Segmented {
                label: "Show"
                current: root.settings.usage_amount_format
                options: [{ value: "used", text: "Used" }, { value: "remaining", text: "Remaining" }]
                onPicked: value => root.apply(["usage_amount_format=" + value])
            }

            Segmented {
                label: "Reset times"
                current: root.settings.reset_time_format
                options: [{ value: "relative", text: "Relative" }, { value: "absolute", text: "Absolute" }]
                onPicked: value => root.apply(["reset_time_format=" + value])
            }

            Segmented {
                label: "Refresh every"
                current: String(root.settings.refresh_interval_seconds)
                options: [{ value: 60, text: "1m" }, { value: 300, text: "5m" },
                          { value: 600, text: "10m" }, { value: 1800, text: "30m" }]
                onPicked: value => root.apply(["refresh_interval_seconds=" + value])
            }

            Segmented {
                label: "Dial label"
                current: root.settings.show_percent ? "true" : "false"
                options: [{ value: false, text: "None" }, { value: true, text: "Session %" }]
                onPicked: value => root.apply(["show_percent=" + value])
            }

            Divider {}

            // --- FOOTER ---
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2

                Text {
                    Layout.fillWidth: true
                    text: "Full breakdown"
                    font.family: Theme.fontFamily
                    font.pixelSize: 12
                    color: breakdownMouse.containsMouse ? Theme.primary : Theme.on_surface
                    leftPadding: 8

                    ToolTip.visible: breakdownMouse.containsMouse
                    ToolTip.text: "Open ccusage weekly --breakdown in a terminal"
                    ToolTip.delay: 400

                    MouseArea {
                        id: breakdownMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["xdg-terminal-exec", "bash", "-c",
                                "npx --yes ccusage@latest weekly --breakdown; read"])
                            root.isOpen = false
                        }
                    }
                }

                Glyph { text: "open_in_new"; font.pixelSize: 15; color: Theme.outline }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
