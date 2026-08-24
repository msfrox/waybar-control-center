// Audio popup for the Waybar `pulseaudio` module.
//
// Waybar's pulseaudio module can show a level and run one command on click; it
// cannot show a mixer. So the module's on-click just calls
//     qs ipc call audio toggle
// and the actual UI lives here, as a layer-shell window.
//
// Everything comes from Quickshell.Services.Pipewire rather than shelling out to
// wpctl/pactl: the node list, per-device volume and mute, and the default-device
// selection are all live properties, so the panel stays in sync when something
// else (a volume key, another app) changes them.
//
// The one non-obvious requirement is PwObjectTracker. A PwNode's `audio` member
// is null until something declares interest in that node, so every node this
// window binds to has to appear in the tracker's `objects` list or its sliders
// read zero and never move.

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import qs.CustomTheme
import qs.Panels

PanelWindow {
    id: root

    // --- WAYLAND CONFIGURATION ---
    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: WlrLayershell.Ignore

    implicitWidth: 420
    // 40 = the 20px inset the card keeps all round for its drop shadow.
    //
    // The cap used to be a flat 900px, which is smaller than this content gets:
    // an Easy Effects list plus per-app streams pushed the column past it and
    // the overflow drew straight out of the bottom of the card. Cap against the
    // actual screen instead, leaving room for the bar and the slide-in margin.
    implicitHeight: Math.min(content.implicitHeight + 80,
                             (screen ? screen.height : 1080) - 140)
    color: "transparent"

    anchors {
        bottom: true
        right: true
    }

    // Matches CalendarWindow: clears the 55px bar by ~10px, and sits 20px in
    // from the right edge once the card's shadow inset is accounted for.
    property real currentBottomMargin: isOpen ? 45 : -1200

    margins {
        bottom: root.currentBottomMargin
        right: 0
    }

    // --- OPEN/CLOSE ---
    property bool isOpen: false
    property bool showWindow: false
    visible: showWindow

    onIsOpenChanged: {
        if (isOpen) {
            showWindow = true
            reloadEffects()
        }
    }

    // --- EASYEFFECTS ---
    //
    // EasyEffects is a PipeWire filter chain, so the device list above shows it
    // as a plain virtual sink called "Easy Effects Sink" with no indication of
    // what it is or which preset it is running. All of that is only reachable
    // through its own CLI, which the helper script wraps.
    property var effects: ({})

    Process {
        id: effectsProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/easyeffects-status.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.effects = JSON.parse(this.text) } catch (e) { root.effects = {} }
            }
        }
    }

    function reloadEffects() {
        if (!effectsProc.running) effectsProc.running = true
    }

    // Applying a preset and toggling bypass both change what the next read
    // reports, so re-read once the command has exited rather than guessing.
    Process { id: effectsAction; onExited: root.reloadEffects() }

    function effectsCommand(args) {
        effectsAction.command = args
        effectsAction.running = true
    }

    Behavior on currentBottomMargin {
        NumberAnimation {
            duration: PanelStyle.animSlower
            easing.type: Easing.OutQuint
            // Unmap only once the hide animation has finished, or Wayland tears
            // the surface down mid-slide.
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
        target: "audio"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- PIPEWIRE ---

    // Filter on `audio`, `isSink` and `isStream` only. Those three are constant
    // properties, set when the node is constructed, so they read correctly on an
    // untracked node. `properties` (and therefore media.class) is NOT - it stays
    // empty until the node is bound, which makes filtering on it circular: the
    // tracker's object list would depend on data only the tracker can produce.
    // Filtering on media.class showed exactly one device, the already-bound
    // default sink, and no inputs at all.
    //
    //   audio !== null  -> an audio node, so video sources drop out
    //   !isStream       -> a device, not an application's playback/record stream
    readonly property var audioNodes: Pipewire.nodes.values.filter(
        n => n.audio && !n.isStream)

    readonly property var sinks: root.audioNodes.filter(n => n.isSink)
    readonly property var sources: root.audioNodes.filter(n => !n.isSink)

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    // Mirror image of the filter above: isStream picks out an application's
    // audio feed instead of a device, and isSink on a stream means it is the
    // playback side (feeding a sink) rather than the recording side (tapping
    // a source) - so this is "what apps are making sound", not "what apps are
    // listening".
    readonly property var streams: Pipewire.nodes.values.filter(
        n => n.audio && n.isStream && n.isSink)

    // Without this, every node's volume and mute read zero and never move.
    PwObjectTracker {
        objects: root.audioNodes.concat(root.streams)
    }

    function label(node) {
        if (!node) return "None"
        return node.description || node.nickname || node.name || "Unknown"
    }

    // Every port on one sound card carries the card's name in its description,
    // so a list of them reads as four identical rows once elided:
    //   "Core Ultra 200H/200V Series Processors HD Audio HD..."
    // PipeWire already publishes the distinguishing tail on its own as
    // `node.nick` ("Speaker", "HDMI / DisplayPort 1 Output"), which Quickshell
    // exposes as `nickname`. Prefer it, and fall back to the long description
    // for nodes that have none - virtual sinks like Easy Effects, mostly.
    // Read it out of `properties` rather than off the `nickname` member:
    // `nickname` is declared constant, so it is captured when the node is
    // constructed - before binding, when it is still empty - and never updates.
    // `properties` has a change signal and fills in once the tracker binds.
    function shortLabel(node) {
        if (!node) return "None"
        const nick = node.properties ? node.properties["node.nick"] : ""
        return nick || node.nickname || node.description || node.name || "Unknown"
    }

    // Streams identify themselves by application, not by the device fields
    // shortLabel() reads - "application.name" is where PipeWire actually puts
    // it, with description/name as fallbacks for streams that omit it.
    function streamLabel(node) {
        if (!node) return "Unknown"
        const appName = node.properties ? node.properties["application.name"] : ""
        return appName || node.description || node.name || "Unknown"
    }

    // --- REUSABLE PIECES ---

    // Material Icons ligature. Deliberately a font glyph rather than an SVG so
    // the app has no asset directory to install alongside it.
    component Glyph: Text {
        font.family: "Material Icons Round"
        font.pixelSize: 20
        color: Theme.primary
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }

    // Icon + slider + percentage. The icon is the mute toggle, which is how
    // every desktop mixer behaves and saves a row of chrome.
    component VolumeRow: RowLayout {
        id: rowRoot
        required property var node
        required property string onIcon
        required property string offIcon

        spacing: Tokens.space.xl
        Layout.fillWidth: true

        readonly property var audio: node ? node.audio : null
        readonly property bool muted: audio ? audio.muted : true

        Rectangle {
            implicitWidth: 34
            implicitHeight: 34
            radius: Tokens.radius.full
            color: rowRoot.muted ? "transparent" : PanelStyle.fillSelected

            Glyph {
                anchors.centerIn: parent
                text: rowRoot.muted ? rowRoot.offIcon : rowRoot.onIcon
                color: rowRoot.muted ? Theme.outline : Theme.primary
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                enabled: rowRoot.audio !== null
                onClicked: rowRoot.audio.muted = !rowRoot.audio.muted
            }
        }

        Slider {
            id: slider
            Layout.fillWidth: true
            from: 0
            to: 1
            // Controls' Slider ignores the wheel unless asked. With it on, a
            // wheel notch moves the handle and emits moved() exactly as a drag
            // does, so the write-back below covers both without branching.
            wheelEnabled: true
            stepSize: 0.02
            // Binding straight to audio.volume would fight the drag, so take the
            // value on change and write back only from the handler.
            value: rowRoot.audio ? rowRoot.audio.volume : 0
            enabled: rowRoot.audio !== null
            onMoved: rowRoot.audio.volume = value

            background: Rectangle {
                x: slider.leftPadding
                y: slider.topPadding + slider.availableHeight / 2 - height / 2
                implicitWidth: 180
                implicitHeight: 6
                width: slider.availableWidth
                height: implicitHeight
                radius: PanelStyle.trackRadius
                color: PanelStyle.fillTrack

                Rectangle {
                    width: slider.visualPosition * parent.width
                    height: parent.height
                    color: rowRoot.muted ? Theme.outline : Theme.primary
                    radius: PanelStyle.trackRadius
                }
            }

            handle: Rectangle {
                x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
                y: slider.topPadding + slider.availableHeight / 2 - height / 2
                implicitWidth: 16
                implicitHeight: 16
                radius: Tokens.radius.full
                color: slider.pressed ? Theme.background : Theme.primary
                border.color: Theme.primary
                border.width: 2
            }
        }

        Text {
            text: Math.round((rowRoot.audio ? rowRoot.audio.volume : 0) * 100) + "%"
            font.family: Theme.fontFamily
            font.pixelSize: 12
            color: Theme.on_surface
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: 38
        }
    }

    // A selectable device. Radio dot on the left so the current default is
    // readable without colour alone.
    component DeviceRow: Rectangle {
        id: devRoot
        required property var node
        required property bool selected
        signal picked

        Layout.fillWidth: true
        implicitHeight: 32
        radius: PanelStyle.buttonRadius
        color: mouse.containsMouse
               ? PanelStyle.fillHover
               : "transparent"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Tokens.space.md
            anchors.rightMargin: Tokens.space.md
            spacing: PanelStyle.panelSpacing

            Rectangle {
                implicitWidth: 12
                implicitHeight: 12
                radius: Tokens.radius.full
                color: "transparent"
                border.width: 2
                border.color: devRoot.selected ? Theme.primary : Theme.outline

                Rectangle {
                    anchors.centerIn: parent
                    width: 6
                    height: 6
                    radius: Tokens.radius.full
                    color: Theme.primary
                    visible: devRoot.selected
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.shortLabel(devRoot.node)
                font.family: Theme.fontFamily
                font.pixelSize: 12
                color: devRoot.selected ? Theme.primary : Theme.on_surface
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: devRoot.picked()
        }
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

                Text {
                    Layout.fillWidth: true
                    text: "Sound"
                    font.family: Theme.fontFamily
                    font.pixelSize: 16
                    font.bold: true
                    color: Theme.primary
                }

                Rectangle {
                    implicitWidth: 28
                    implicitHeight: 28
                    radius: PanelStyle.buttonRadius
                    color: settingsMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"

                    ToolTip.visible: settingsMouse.containsMouse
                    ToolTip.text: "Open pavucontrol for per-app stream routing"
                    ToolTip.delay: 400

                    Glyph {
                        anchors.centerIn: parent
                        text: "tune"
                        font.pixelSize: 17
                    }

                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["pavucontrol"])
                            root.isOpen = false
                        }
                    }
                }
            }

            Divider {}

            // --- OUTPUT ---
            SectionLabel { text: "Output" }

            VolumeRow {
                node: root.sink
                onIcon: "volume_up"
                offIcon: "volume_off"
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs

                Repeater {
                    model: root.sinks
                    DeviceRow {
                        required property var modelData
                        node: modelData
                        selected: root.sink && modelData.id === root.sink.id
                        onPicked: Pipewire.preferredDefaultAudioSink = modelData
                    }
                }
            }

            Divider { visible: root.sources.length > 0 }

            // --- INPUT ---
            // Hidden wholesale on a machine with no capture device, rather than
            // showing a dead slider next to a "none" message.
            SectionLabel {
                text: "Input"
                visible: root.sources.length > 0
            }

            VolumeRow {
                node: root.source
                onIcon: "mic"
                offIcon: "mic_off"
                visible: root.sources.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.sources.length > 0

                Repeater {
                    model: root.sources
                    DeviceRow {
                        required property var modelData
                        node: modelData
                        selected: root.source && modelData.id === root.source.id
                        onPicked: Pipewire.preferredDefaultAudioSource = modelData
                    }
                }
            }

            Divider { visible: root.streams.length > 0 }

            // --- APPLICATIONS ---
            // Hidden wholesale when nothing is playing, same reasoning as INPUT:
            // an empty "Applications" heading is noise, not information.
            SectionLabel {
                text: "Applications"
                visible: root.streams.length > 0
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: PanelStyle.panelSpacing
                visible: root.streams.length > 0

                Repeater {
                    model: root.streams
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Tokens.space.xxs

                        Text {
                            Layout.fillWidth: true
                            text: root.streamLabel(modelData)
                            font.family: Theme.fontFamily
                            font.pixelSize: 12
                            color: Theme.on_surface
                            elide: Text.ElideRight
                        }

                        VolumeRow {
                            node: modelData
                            onIcon: "volume_up"
                            offIcon: "volume_off"
                        }
                    }
                }
            }

            // --- EASYEFFECTS ---
            Divider { visible: !!root.effects.available }

            RowLayout {
                Layout.fillWidth: true
                visible: !!root.effects.available
                spacing: PanelStyle.panelSpacing

                SectionLabel { Layout.fillWidth: true; text: "Easy Effects" }

                // Bypass, not quit: quitting drops the filter chain out of the
                // graph and moves every stream, which is a much bigger hammer
                // than "let me hear it without the effects for a second".
                Text {
                    text: root.effects.bypassed ? "Bypassed" : "Active"
                    font.family: Theme.fontFamily
                    font.pixelSize: 11
                    color: root.effects.bypassed ? Theme.outline
                         : bypassMouse.containsMouse ? Theme.primary : Theme.primary

                    ToolTip.visible: bypassMouse.containsMouse
                    ToolTip.text: "Bypass all Easy Effects processing"
                    ToolTip.delay: 400

                    MouseArea {
                        id: bypassMouse
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.effectsCommand(["easyeffects", "--bypass-toggle"])
                    }
                }

                Rectangle {
                    implicitWidth: 24
                    implicitHeight: 24
                    radius: PanelStyle.buttonRadius
                    color: eeMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"

                    ToolTip.visible: eeMouse.containsMouse
                    ToolTip.text: "Open the Easy Effects window"
                    ToolTip.delay: 400

                    Glyph { anchors.centerIn: parent; text: "graphic_eq"; font.pixelSize: 15 }

                    MouseArea {
                        id: eeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["easyeffects"])
                            root.isOpen = false
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: !!root.effects.available && !root.effects.running
                text: "Not running — effects are not in the audio graph"
                font.family: Theme.fontFamily
                font.pixelSize: 11
                color: Theme.outline
                leftPadding: Tokens.space.md
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: !!root.effects.available && !!root.effects.running

                Repeater {
                    model: root.effects.output_presets || []

                    DeviceRow {
                        required property var modelData
                        // DeviceRow labels itself from a PipeWire node; here the
                        // name is already the label, so hand it a stand-in with
                        // the shape the component reads.
                        node: ({ nickname: modelData })
                        selected: modelData === root.effects.output_preset
                        onPicked: root.effectsCommand(["easyeffects", "-l", modelData])
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
