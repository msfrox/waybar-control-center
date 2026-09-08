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
import qs.BarApp // BarReveal

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

    // Holds hyprbar's auto-hiding bar open while this popout is on screen --
    // BarReveal is a QML singleton shared by every file in this one
    // Quickshell process, so this needs no IPC round trip even though
    // AudioWindow and BarWindow live in separate app directories.
    // 📄 hyprbar docs/26-path-to-v1.md §B11, brilliant repo
    onIsOpenChanged: {
        if (isOpen) {
            showWindow = true
            reloadEffects()
            BarReveal.acquire("audio")
        } else {
            BarReveal.release("audio")
            // Reopening should start with no row lit, same as any first open —
            // not resume a highlight left over a list that has since reordered
            // itself (audio devices are LIVE; see KeyNav.qml's own header).
            nav.clear()
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

    // --- KEYBOARD ---
    //
    // 2026-09-07 reachability audit: this panel was a stack of Repeaters over
    // live PipeWire arrays with every row a bare MouseArea — no Tab, no
    // arrows, no Enter. KeyNav.qml (Panels/KeyNav.qml, read its header before
    // touching this) is the shared fix for that, copied in shape from
    // hyprbar's SwitcherWindow.qml: one flat cursor over sections declared in
    // visual order, this file's own Keys.onPressed decides what a key means
    // for whichever section the cursor is currently in.
    //
    // Six sections, not four, because two on-screen row TYPES sit under each
    // of the "Output"/"Input" headings — a master mute/volume row, then a
    // list of device-pick rows — and they need different Enter behaviour
    // (toggle mute vs. make default), which is exactly what KeyNav pushes
    // onto per-section branching rather than owning itself. Easy Effects
    // presets are included too: they are DeviceRow-shaped, mouse-only rows
    // like everything else here, and leaving them out would just move the
    // audit's defect three rows down instead of closing it.
    //
    // Every `items:` list mirrors an existing `visible:` binding on the
    // ColumnLayout/row below it EXACTLY, rather than restating the condition
    // in a new form — see KeyNav.qml's header on why a cursor must never be
    // able to land on a row that is not on screen. `outputDevices`/
    // `inputDevices`/`appVolumes` need no ternary: their source arrays
    // (`root.sinks`/`root.sources`/`root.streams`) are already empty in
    // exactly the cases the matching container hides, so passing them
    // straight through already agrees with the visible: binding for free.
    // `outputMaster` has no ternary either — that row carries no `visible:`
    // condition of its own, so it is always reachable. `inputMaster` and
    // `easyEffectsPresets` DO need one: each is a single row (not a Repeater)
    // gated by a `visible:` a plain array pass-through cannot express.
    readonly property var navSections: [
        { id: "outputMaster",  items: [root.sink] },
        { id: "outputDevices", items: root.sinks },
        { id: "inputMaster",   items: root.sources.length > 0 ? [root.source] : [] },
        { id: "inputDevices",  items: root.sources },
        { id: "appVolumes",    items: root.streams },
        { id: "easyEffectsPresets",
          items: (!!root.effects.available && !!root.effects.running)
                 ? (root.effects.output_presets || []) : [] }
    ]

    KeyNav {
        id: nav
        sections: root.navSections
    }

    // The one step size this file already had an opinion about: the Slider's
    // own `wheelEnabled`/`stepSize` below. Left/Right on a slider row reuses
    // it rather than inventing a second number, so a keyboard nudge and a
    // wheel notch move the handle by the same amount.
    readonly property real volumeStep: 0.02

    // --- ROW ACTIONS — the ONLY place each of these is implemented. Every
    // MouseArea/Slider handler below calls one of these, and so does the key
    // handler, because BUGS.md already paid for the alternative ("one correct
    // call site does not protect the second one").
    function setDefaultSink(node) {
        if (node) Pipewire.preferredDefaultAudioSink = node
    }

    function setDefaultSource(node) {
        if (node) Pipewire.preferredDefaultAudioSource = node
    }

    function toggleMute(node) {
        if (node && node.audio) node.audio.muted = !node.audio.muted
    }

    function setVolume(node, value) {
        if (!node || !node.audio) return
        node.audio.volume = Math.max(0, Math.min(1, value))
    }

    function nudgeVolume(node, delta) {
        if (!node || !node.audio) return
        root.setVolume(node, node.audio.volume + delta)
    }

    // Which node, if any, the slider under the cursor should nudge. Only the
    // three sections that ARE a volume row answer; device-pick rows have no
    // slider and correctly return null so Left/Right falls through as a
    // no-op for them.
    function currentSliderNode() {
        switch (nav.currentSection) {
        case "outputMaster": return root.sink
        case "inputMaster": return root.source
        case "appVolumes": return nav.currentItem
        default: return null
        }
    }

    // Enter: branches on nav.currentSection exactly the way SwitcherWindow's
    // commit() branches on entries[selectedIndex].type — moving the cursor
    // never needed to know which section it was in, only activating it does.
    function activateCurrent() {
        const sliderNode = root.currentSliderNode()
        if (sliderNode) {
            root.toggleMute(sliderNode)
            return
        }
        switch (nav.currentSection) {
        case "outputDevices":
            root.setDefaultSink(nav.currentItem)
            break
        case "inputDevices":
            root.setDefaultSource(nav.currentItem)
            break
        case "easyEffectsPresets":
            if (nav.currentItem) root.effectsCommand(["easyeffects", "-l", nav.currentItem])
            break
        }
    }

    function muteCurrent() {
        const node = root.currentSliderNode()
        if (node) root.toggleMute(node)
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
    //
    // Root is a Rectangle, not a bare RowLayout, for the same reason
    // DeviceRow below already is one: the KeyNav cursor highlight needs
    // somewhere to paint that isn't fighting the RowLayout for a layout slot.
    // `sectionId`/`row` are blank/0 by default — this component is reused by
    // three different KeyNav sections (outputMaster, inputMaster,
    // appVolumes) that each pass their own, so a hover on ANY of them moves
    // the one shared cursor (ADR-0018 rule 4) rather than each row silently
    // owning a private hover state the way this used to work.
    component VolumeRow: Rectangle {
        id: rowRoot
        required property var node
        required property string onIcon
        required property string offIcon
        property string sectionId: ""
        property int row: 0

        Layout.fillWidth: true
        implicitHeight: layout.implicitHeight
        radius: PanelStyle.buttonRadius
        color: rowRoot.current ? PanelStyle.fillCursor : "transparent"

        readonly property var audio: node ? node.audio : null
        readonly property bool muted: audio ? audio.muted : true
        readonly property bool current: rowRoot.sectionId !== "" && nav.isCurrent(rowRoot.sectionId, rowRoot.row)

        RowLayout {
            id: layout
            anchors.fill: parent
            spacing: Tokens.space.xl

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
                    hoverEnabled: true
                    onEntered: if (rowRoot.sectionId !== "") nav.setCurrent(rowRoot.sectionId, rowRoot.row)
                    onClicked: root.toggleMute(rowRoot.node)
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
                // Same number the keyboard's Left/Right uses (root.volumeStep) —
                // see this file's own `--- KEYBOARD ---` section for why a
                // slider row is the one place Left/Right means something at all.
                wheelEnabled: true
                stepSize: root.volumeStep
                hoverEnabled: true
                onHoveredChanged: if (hovered && rowRoot.sectionId !== "") nav.setCurrent(rowRoot.sectionId, rowRoot.row)
                // Binding straight to audio.volume would fight the drag, so take the
                // value on change and write back only from the handler.
                value: rowRoot.audio ? rowRoot.audio.volume : 0
                enabled: rowRoot.audio !== null
                onMoved: root.setVolume(rowRoot.node, value)

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
    }

    // A selectable device. Radio dot on the left so the current default is
    // readable without colour alone.
    //
    // `sectionId`/`row` are blank/-1 by default (the Easy Effects "not
    // running" fallback state never instantiates this at all, so there is no
    // third caller to worry about) — set by whichever Repeater places this
    // in a KeyNav section. `current` wins over plain mouse hover in the
    // colour below because, per KeyNav's own rule, hovering IS how the mouse
    // moves this same cursor (see the MouseArea's onEntered) — there is no
    // second "just hovered, not current" state left to draw once a hover
    // has already happened.
    component DeviceRow: Rectangle {
        id: devRoot
        required property var node
        required property bool selected
        property string sectionId: ""
        property int row: -1
        readonly property bool current: devRoot.sectionId !== "" && nav.isCurrent(devRoot.sectionId, devRoot.row)
        signal picked

        Layout.fillWidth: true
        implicitHeight: 32
        radius: PanelStyle.buttonRadius
        color: devRoot.current ? PanelStyle.fillCursor
               : mouse.containsMouse ? PanelStyle.fillHover
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
            onEntered: if (devRoot.sectionId !== "") nav.setCurrent(devRoot.sectionId, devRoot.row)
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
                sectionId: "outputMaster"
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs

                Repeater {
                    model: root.sinks
                    DeviceRow {
                        required property var modelData
                        required property int index
                        node: modelData
                        selected: root.sink && modelData.id === root.sink.id
                        sectionId: "outputDevices"
                        row: index
                        onPicked: root.setDefaultSink(modelData)
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
                sectionId: "inputMaster"
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.xxs
                visible: root.sources.length > 0

                Repeater {
                    model: root.sources
                    DeviceRow {
                        required property var modelData
                        required property int index
                        node: modelData
                        selected: root.source && modelData.id === root.source.id
                        sectionId: "inputDevices"
                        row: index
                        onPicked: root.setDefaultSource(modelData)
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
                        required property int index
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
                            sectionId: "appVolumes"
                            row: index
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
                        required property int index
                        // DeviceRow labels itself from a PipeWire node; here the
                        // name is already the label, so hand it a stand-in with
                        // the shape the component reads.
                        node: ({ nickname: modelData })
                        selected: modelData === root.effects.output_preset
                        sectionId: "easyEffectsPresets"
                        row: index
                        onPicked: root.effectsCommand(["easyeffects", "-l", modelData])
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
    }

    // --- KEYBOARD, continued: the actual key catcher. Declared as a sibling
    // of the visual card rather than nested inside it — same placement
    // SwitcherWindow.qml uses for its own `keyCatcher` — because focus is a
    // property of THIS Item, not of anything it draws, and it needs
    // `anchors.fill: parent` against the window's contentItem the same way
    // the card above already does.
    //
    // `focus: root.isOpen`, not `WlrLayershell.keyboardFocus`. This panel
    // already gets its keyboard input through the existing
    // HyprlandFocusGrab above (see this file's own header on why: changing
    // keyboard focus mode risks the panel holding the keyboard against the
    // compositor, and NetworkWindow.qml's password field already proves
    // plain `focus:` is enough).
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.isOpen

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Tab:
                if (event.modifiers & Qt.ShiftModifier)
                    nav.moveBy(-1)
                else
                    nav.moveBy(1)
                event.accepted = true
                break
            case Qt.Key_Backtab:
                // Some platforms deliver Shift+Tab as Backtab rather than Tab
                // + ShiftModifier — handle both rather than assume one.
                nav.moveBy(-1)
                event.accepted = true
                break
            case Qt.Key_Down:
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
            case Qt.Key_Left:
            case Qt.Key_Right: {
                // THE ONE NON-OBVIOUS KEY IN THIS FILE. Everywhere else in
                // this desktop's panels, Left/Right either do nothing or
                // move a selection — but a volume row's real action is a
                // continuous value, not a commit, so nudging it by one step
                // is the honest keyboard expression of "the slider under the
                // cursor", not a stand-in for Enter. It only fires when the
                // cursor is actually ON a slider row (currentSliderNode()
                // returns null for a device-pick row); elsewhere the event
                // is left unaccepted rather than silently eaten, so nothing
                // downstream loses it for no reason.
                const node = root.currentSliderNode()
                if (!node)
                    break
                root.nudgeVolume(node, event.key === Qt.Key_Left ? -root.volumeStep : root.volumeStep)
                event.accepted = true
                break
            }
            case Qt.Key_Return:
            case Qt.Key_Enter:
                root.activateCurrent()
                event.accepted = true
                break
            case Qt.Key_M:
                // No text input exists anywhere in this panel (checked before
                // adding this — see the report), so a bare M is safe to claim
                // as a mute toggle without shadowing a search field.
                root.muteCurrent()
                event.accepted = true
                break
            }
        }
    }
}
