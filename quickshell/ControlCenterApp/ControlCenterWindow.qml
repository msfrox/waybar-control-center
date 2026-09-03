// Control Center - a full-height panel that slides in from the right.
//
// The bar had accumulated things that only work as a hover-out drawer: a
// hardware group, a tools group, a tray drawer. Those are fine as a shortcut
// and bad as a home - they are invisible until you know they are there, they
// vanish when the pointer leaves, and each one costs permanent width on a bar
// that also wants to show a taskbar.
//
// So this is the home, and the bar keeps only what is worth a permanent glance.
// The point of the first version is the FRAME, not the contents: a right-anchored
// full-height surface, a scrollable column, and a Section component that further
// modules drop into without touching anything else here.
//
// Migration is deliberately incremental - a module stays on the bar until its
// equivalent here is at least as good.
//
// Window chrome is duplicated from AudioWindow on purpose; see the note at the
// top of BluetoothWindow.qml.

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import qs.CustomTheme
import qs.NotificationCenterApp
// The shared panel look. This window is where that look was FIRST worked out,
// so nothing here changes shape by adopting it — but the numbers now live in
// one file (quickshell/Panels/PanelStyle.qml) instead of being copied into
// every other panel and popout by hand, which is how they had already drifted.
//
// The inline `Glyph` and `Section` components below shadow the imported types
// of the same name: QML resolves inline components in the document ahead of
// anything an import brings in. They stay local because both carry
// control-centre-only behaviour (persisted collapse state, hide-a-section) that
// does not belong in the shared set. Migrating them is follow-up work, not a
// prerequisite — the tokens are the part that has to be shared.
import qs.Panels
import qs.BarApp // BarReveal

PanelWindow {
    id: root

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: WlrLayershell.Ignore

    implicitWidth: 460
    color: "transparent"

    // Bottom-anchored and content-sized rather than full height: a panel pinned
    // to both vertical edges is mostly empty space on a 2560px-tall screen, and
    // it reads as a second desktop rather than as something the bar opened.
    // The cap is a last-resort guard against running off the top of the
    // screen, not a scroll threshold - there is no scroll view any more.
    // Pushed up from the body rather than read down into it: referencing the
    // scroll column's id from here is a forward reference the root's
    // implicitHeight binding evaluates before that object exists, which throws
    // "ReferenceError: body is not defined" and leaves the window unsized.
    //
    // 160 = the card's 20px shadow inset top and bottom, its 20px inner padding
    // top and bottom, the header row, and the divider under it.
    property real bodyHeight: 0
    implicitHeight: Math.min(root.bodyHeight + 160, 2400)

    anchors {
        right: true
        bottom: true
    }

    property bool isOpen: false
    property bool showWindow: false
    visible: showWindow

    // See AudioWindow.qml's comment: BarReveal is a shared singleton, no IPC
    // round trip needed even across app directories in this one process.
    onIsOpenChanged: {
        if (isOpen) {
            showWindow = true
            refresh()
            reloadBrightness()
            reloadWeather()
            BarReveal.acquire("control-center")
        } else {
            BarReveal.release("control-center")
        }
    }

    // Slides in from the right edge. Same 45px bottom margin as the popups, so
    // its lower edge lines up with theirs above the 55px bar.
    property real currentRightMargin: isOpen ? 0 : -520

    margins {
        bottom: 45
        right: root.currentRightMargin
    }

    Behavior on currentRightMargin {
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
        target: "control-center"
        function toggle(): void { root.isOpen = !root.isOpen }
        function open(): void { root.isOpen = true }
        function close(): void { root.isOpen = false }
        function isOpen(): bool { return root.isOpen }
    }

    // --- SYSTEM STATS ---
    property var stats: ({})

    Process {
        id: statsProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/system-stats.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.stats = JSON.parse(this.text) } catch (e) {}
            }
        }
    }

    function refresh() {
        if (!statsProc.running) statsProc.running = true
    }

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.isOpen
        onTriggered: root.refresh()
    }

    // --- BRIGHTNESS ---
    // Read once, on open, and never polled. Both readings are expensive in their own
    // way -- the external monitor is a DDC/CI round-trip over I2C, which is slow and
    // does not like being hammered -- and neither needs to be repeated: while the
    // panel is up, the slider itself is the authority on what the brightness is. The
    // percentage beside it tracks the handle, not a reading, so a drag reads back
    // instantly with no process spawned to confirm it.
    //
    // The cost is that pressing the laptop's brightness keys with the panel already
    // open leaves the internal slider stale until it is reopened. That was worth a
    // 2-second poll when only the internal panel could be polled cheaply; it is not
    // worth one now that the external slider -- which cannot be polled cheaply at
    // all -- is the one being used.
    property var brightness: ({})

    Process {
        id: brightnessProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/brightness.py", "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.brightness = JSON.parse(this.text) } catch (e) {}
            }
        }
    }

    function reloadBrightness() {
        if (!brightnessProc.running) brightnessProc.running = true
    }

    // --- WEATHER ---
    // Read on open only. weather.py caches to disk for 30 minutes and serves the
    // cached copy without touching the network, so opening the panel repeatedly
    // costs a file read; putting this on the stats tick would gain nothing and
    // would eventually earn a 503 from wttr.in.
    property var weather: ({})

    Process {
        id: weatherProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/weather.py"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.weather = JSON.parse(this.text) } catch (e) {}
            }
        }
    }

    Process {
        id: weatherRefreshProc
        command: [Quickshell.env("HOME") + "/.config/brilliant/providers/weather.py",
                  "--refresh"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.weather = JSON.parse(this.text) } catch (e) {}
            }
        }
    }

    function reloadWeather() {
        if (!weatherProc.running) weatherProc.running = true
    }

    function refreshWeather() {
        if (!weatherRefreshProc.running) weatherRefreshProc.running = true
    }

    Process { id: brightnessSet }

    // Debounced: a drag emits a value on every pixel, and each external write is
    // a DDC round-trip. Only the value the slider settles on is actually sent.
    Timer {
        id: brightnessDebounce
        interval: 120
        repeat: false
        property string target: ""
        property int value: 0
        onTriggered: {
            brightnessSet.command = [
                Quickshell.env("HOME") + "/.config/brilliant/providers/brightness.py",
                "set", target, String(value)]
            brightnessSet.running = true
        }
    }

    function setBrightness(target, value) {
        brightnessDebounce.target = target
        brightnessDebounce.value = value
        brightnessDebounce.restart()
    }

    // --- PENDING UPDATES ---
    // Kept off the stats tick on purpose: this hits the package databases and
    // takes seconds, so it runs on open and then only every 30 minutes - the
    // same cadence the bar module used.
    property int updateCount: 0

    // Counting and installing come from different places on purpose. The count
    // stays on one shared script so the bar, the app launcher and this tile
    // cannot disagree about the number -- that script was ML4W's and was rescued
    // to `brilliant-check-updates` on 2026-08-19, keeping the single-source
    // property intact. Installing does not share: ML4W's
    // installupdates.sh opens a terminal on a script whose first command is
    // `figlet`, and neither figlet nor the `gum` it prompts with is installed
    // here, so the window appeared and died before asking anything. `arch-update`
    // is interactive, so it still needs a terminal of its own.
    readonly property string updateCommand: "kitty --class dotfiles-floating -e arch-update"

    Process {
        id: updatesProc
        // Used to shell out to ml4w-check-system-updates under the ML4W tree;
        // that tree is being deleted, so this now calls the rescued copy that
        // lives on $PATH under its own name.
        command: [Quickshell.env("HOME") + "/.local/bin/brilliant-check-updates"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const payload = JSON.parse(this.text)
                    root.updateCount = parseInt(payload.text) || 0
                } catch (e) {
                    root.updateCount = 0
                }
            }
        }
    }

    Timer {
        interval: 1800000
        repeat: true
        triggeredOnStart: true
        running: root.isOpen
        onTriggered: if (!updatesProc.running) updatesProc.running = true
    }

    // Runs a shell command and closes the panel - the shape every quick action
    // that hands off to another window takes.
    function launch(command) {
        Quickshell.execDetached(["bash", "-c", command])
        root.isOpen = false
    }

    // Runs a shell command and stays open, then re-reads state so the tile's
    // active styling catches up with what just happened.
    Process { id: toggleProc; onExited: root.refresh() }

    function toggleAction(command) {
        toggleProc.command = ["bash", "-c", command]
        toggleProc.running = true
    }

    // --- FORMATTING ---
    function humanBytes(bytes) {
        if (bytes === null || bytes === undefined) return "—"
        const units = ["B", "KB", "MB", "GB", "TB"]
        let value = bytes, i = 0
        while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
        return (value >= 10 || i === 0 ? Math.round(value) : value.toFixed(1)) + " " + units[i]
    }

    function humanRate(bytesPerSecond) {
        if (bytesPerSecond === null || bytesPerSecond === undefined) return "—"
        return humanBytes(bytesPerSecond) + "/s"
    }

    function humanUptime(seconds) {
        if (!seconds) return "—"
        const days = Math.floor(seconds / 86400)
        const hours = Math.floor((seconds % 86400) / 3600)
        const mins = Math.floor((seconds % 3600) / 60)
        if (days > 0) return days + "d " + hours + "h"
        if (hours > 0) return hours + "h " + mins + "m"
        return mins + "m"
    }

    // stats.tools is undefined until the first read, and every tile binds to it
    // - one accessor beats repeating the guard at a dozen call sites.
    function tool(key) {
        return root.stats.tools ? root.stats.tools[key] : undefined
    }

    function loadColor(percent) {
        if (percent >= 90) return Theme.error
        if (percent >= 70) return Theme.tertiary
        return Theme.primary
    }

    // --- PERSISTED PANEL STATE ---
    // All keyed by title/label rather than index: sections and tiles get
    // reordered in this file far more often than the persisted file gets
    // touched, and a name survives a reorder where an index wouldn't.
    property var collapseState: ({})

    // Which sections and quick-action tiles are hidden. Stored as *hidden*
    // rather than *visible* on purpose: an absent key, an empty object and a
    // missing file all have to mean "show it". Storing visibility instead
    // would make a section added later default to invisible until somebody
    // edited the file, which is how a new feature ships broken.
    property var hiddenSections: ({})
    property var hiddenActions: ({})

    function isSectionHidden(title) {
        return root.hiddenSections[title] === true
    }

    function isActionHidden(label) {
        return root.hiddenActions[label] === true
    }

    function setSectionCollapsed(title, collapsed) {
        const next = Object.assign({}, root.collapseState)
        next[title] = collapsed
        root.collapseState = next
        Quickshell.execDetached(["brilliant-setting", "set", "--json", "controlCenter.collapsed", JSON.stringify(next)])
    }

    // --- CATALOGUE ---
    // What sections and quick actions this panel actually has, written into
    // the settings file so another process can offer them without keeping its
    // own copy of the list.
    //
    // This panel is the only thing that knows what it contains, and the lists
    // are read off the live children rather than hand-maintained beside them:
    // a hand-maintained copy is a second source of truth that goes stale the
    // first time somebody adds a section and forgets.
    function collectCatalogue() {
        const sections = []
        for (let i = 0; i < body.children.length; i++) {
            const child = body.children[i]
            if (child && child.title !== undefined && child.title !== "")
                sections.push(child.title)
        }
        const actions = []
        for (let i = 0; i < quickGrid.children.length; i++) {
            const child = quickGrid.children[i]
            if (child && child.label !== undefined && child.label !== "")
                actions.push(child.label)
        }
        return { sections: sections, actions: actions }
    }

    // Written only when it has actually changed. The FileView watches this
    // file, so an unconditional write on load would reload, re-publish and
    // write again forever.
    function publishCatalogue() {
        const found = root.collectCatalogue()
        if (JSON.stringify(found.sections) === JSON.stringify(settings.controlCenter.sections)
            && JSON.stringify(found.actions) === JSON.stringify(settings.controlCenter.actions))
            return
        Quickshell.execDetached(["brilliant-setting", "set", "--json", "controlCenter.sections", JSON.stringify(found.sections)])
        Quickshell.execDetached(["brilliant-setting", "set", "--json", "controlCenter.actions", JSON.stringify(found.actions)])
    }

    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/brilliant/brilliant.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.collapseState = settings.controlCenter.collapsed
            root.hiddenSections = settings.controlCenter.hiddenSections
            root.hiddenActions = settings.controlCenter.hiddenActions
            root.publishCatalogue()
            // Picks up a location edit without a restart. Cheap: weather.py only
            // reaches the network when the location actually changed or the cache
            // has aged out, so the writes this panel does itself cost a file read.
            root.reloadWeather()
        }

        // No file yet is the normal first-run case, not an error - every
        // section just keeps its collapsed: false default below.
        onLoadFailed: (error) => {}

        // brilliant.json is shared with unrelated top-level namespaces
        // (appearance, apps, bar, keybinds, nightlight, notifications, power,
        // quicklinks, screenshot, wallpaper, windowRules, ...). Only
        // `controlCenter` is declared here. Writes MUST go through
        // `brilliant-setting`, never settingsFile.writeAdapter() — that call
        // serialises only the properties declared on this JsonAdapter and
        // would silently wipe every other namespace in the file.
        JsonAdapter {
            id: settings
            property var controlCenter: ({
                collapsed: {},
                hiddenSections: {},
                hiddenActions: {},
                // Published by this panel, read by hyprsys. Not settings — a
                // description of what settings exist.
                sections: [],
                actions: [],
                // Read by weather.py, never written here.
                weather_location: ""
            })
        }
    }

    // --- SHARED PIECES ---
    component Glyph: Text {
        font.family: PanelStyle.iconFamily
        font.pixelSize: PanelStyle.iconSize
        color: PanelStyle.textAccent
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
    }

    // The unit every future module plugs into: a titled, collapsible block.
    // Anything added to `content` inherits the panel's spacing and its
    // collapse behaviour for free.
    component Section: ColumnLayout {
        id: section
        required property string title
        property string glyph: ""
        // Bound rather than a plain default, so a title missing from
        // collapseState - a brand new section, or a first run with no file
        // yet - falls through to false instead of coming up collapsed.
        property bool collapsed: root.collapseState.hasOwnProperty(section.title)
                                  ? root.collapseState[section.title] : false
        default property alias content: holder.data

        // Hiding a section removes it from the layout entirely rather than
        // leaving a gap: an invisible item in a ColumnLayout takes no space.
        visible: !root.isSectionHidden(section.title)

        Layout.fillWidth: true
        spacing: Tokens.space.sm

        // The header is wrapped in a plain Item so the click target can use
        // anchors: a MouseArea placed directly in a Layout is layout-managed,
        // and anchoring it is undefined behaviour that Qt warns about.
        Item {
            Layout.fillWidth: true
            implicitHeight: 24

            RowLayout {
                anchors.fill: parent
                spacing: Tokens.space.md

                Glyph {
                    text: section.glyph
                    font.pixelSize: 16
                    visible: section.glyph !== ""
                }

                Text {
                    Layout.fillWidth: true
                    text: section.title
                    font.family: PanelStyle.fontFamily
                    font.pixelSize: 11
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1
                    color: Theme.outline
                }

                Glyph {
                    text: section.collapsed ? "expand_more" : "expand_less"
                    font.pixelSize: 18
                    color: Theme.outline
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                // Through setSectionCollapsed rather than a direct toggle -
                // assigning section.collapsed here would break the binding
                // above, so a later file reload could never reach it again.
                onClicked: root.setSectionCollapsed(section.title, !section.collapsed)
            }
        }

        ColumnLayout {
            id: holder
            Layout.fillWidth: true
            spacing: Tokens.space.sm
            visible: !section.collapsed
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.space.xs
            implicitHeight: 1
            color: Theme.primary
            opacity: Tokens.opacity.separator
        }
    }

    // A labelled usage bar - CPU, memory, disk all read the same way.
    component StatBar: ColumnLayout {
        id: statRoot
        required property string label
        required property real percent
        property string detail: ""

        Layout.fillWidth: true
        spacing: 3

        RowLayout {
            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: statRoot.label
                font.family: PanelStyle.fontFamily
                font.pixelSize: 12
                color: Theme.on_surface
            }

            Text {
                text: statRoot.detail
                font.family: PanelStyle.fontFamily
                font.pixelSize: 10
                color: Theme.outline
                rightPadding: Tokens.space.md
            }

            Text {
                text: Math.round(statRoot.percent) + "%"
                font.family: PanelStyle.fontFamily
                font.pixelSize: 12
                font.bold: true
                color: root.loadColor(statRoot.percent)
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 6
            radius: PanelStyle.trackRadius
            color: PanelStyle.fillTrack

            Rectangle {
                width: parent.width * Math.min(1, Math.max(0, statRoot.percent / 100))
                height: parent.height
                radius: PanelStyle.trackRadius
                color: root.loadColor(statRoot.percent)
                Behavior on width { NumberAnimation { duration: PanelStyle.animSlow } }
            }
        }
    }

    // A quick action. `active` gives it the accent fill, which is what makes a
    // toggle readable at a glance without a separate state label.
    component ToolTile: Rectangle {
        id: tile
        required property string glyph
        required property string label
        property string detail: ""
        property string hint: ""
        property bool active: false
        signal triggered

        // A hidden tile leaves no hole in the grid — GridLayout reflows around
        // invisible children, so the remaining tiles close up.
        visible: !root.isActionHidden(tile.label)

        // The tile shows `detail` (the current state) rather than `label`, so
        // without this there is nowhere the tile says what it *is*.
        ToolTip.visible: tileMouse.containsMouse && tile.hint !== ""
        ToolTip.text: tile.hint
        ToolTip.delay: 400

        Layout.fillWidth: true
        implicitHeight: 56
        radius: PanelStyle.controlRadius
        color: active ? Theme.primary
                      : tileMouse.containsMouse
                        ? PanelStyle.fillHover
                        : PanelStyle.fillSubtle
        Behavior on color { ColorAnimation { duration: PanelStyle.animNormal } }
        clip: true

        ColumnLayout {
            anchors.centerIn: parent
            spacing: Tokens.space.hairline

            Glyph {
                Layout.alignment: Qt.AlignHCenter
                text: tile.glyph
                font.pixelSize: 18
                color: tile.active ? Theme.on_primary : Theme.primary
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: tile.detail !== "" ? tile.detail : tile.label
                font.family: PanelStyle.fontFamily
                font.pixelSize: 10
                color: tile.active ? Theme.on_primary : Theme.on_surface
            }
        }

        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tile.triggered()
        }
    }

    // Icon + slider + percentage, for the two brightness controls.
    component BrightnessRow: RowLayout {
        id: brow
        required property string glyph
        required property string label
        required property int percent
        property string hint: ""
        signal moved(int value)

        Layout.fillWidth: true
        spacing: Tokens.space.xl

        Glyph {
            text: brow.glyph
            font.pixelSize: 18

            ToolTip.visible: browHover.containsMouse && brow.hint !== ""
            ToolTip.text: brow.hint
            ToolTip.delay: 400

            MouseArea {
                id: browHover
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
            }
        }

        Slider {
            id: brightSlider
            Layout.fillWidth: true
            from: 1
            to: 100
            value: brow.percent
            onMoved: brow.moved(Math.round(value))

            // Dragging a Slider assigns `value` imperatively, and that destroys the
            // `value: brow.percent` binding above for good - so the next reading on
            // open would land in a property nothing was watching, and the handle
            // would stay where it was last dragged. Re-assert the binding on each new
            // reading, but never while the handle is held.
            Connections {
                target: brow
                function onPercentChanged() {
                    if (!brightSlider.pressed) brightSlider.value = brow.percent
                }
            }

            background: Rectangle {
                x: brightSlider.leftPadding
                y: brightSlider.topPadding + brightSlider.availableHeight / 2 - height / 2
                implicitHeight: 6
                width: brightSlider.availableWidth
                height: implicitHeight
                radius: PanelStyle.trackRadius
                color: PanelStyle.fillTrack

                Rectangle {
                    width: brightSlider.visualPosition * parent.width
                    height: parent.height
                    radius: PanelStyle.trackRadius
                    color: Theme.primary
                }
            }

            handle: Rectangle {
                x: brightSlider.leftPadding + brightSlider.visualPosition * (brightSlider.availableWidth - width)
                y: brightSlider.topPadding + brightSlider.availableHeight / 2 - height / 2
                implicitWidth: 16
                implicitHeight: 16
                radius: Tokens.radius.full
                color: brightSlider.pressed ? Theme.background : Theme.primary
                border.color: Theme.primary
                border.width: 2
            }
        }

        Text {
            // The handle, not the last reading. `brow.percent` is only refreshed when
            // the panel opens, so reading from it left the number frozen at the value
            // the slider started on for the whole drag - most visibly on the external
            // monitor, whose reading is never refreshed while the panel is up at all.
            text: Math.round(brightSlider.value) + "%"
            font.family: PanelStyle.fontFamily
            font.pixelSize: 12
            color: Theme.on_surface
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: 38
        }
    }

    component InfoPill: Rectangle {
        id: pill
        required property string glyph
        required property string value
        required property string caption

        Layout.fillWidth: true
        implicitHeight: 48
        radius: PanelStyle.controlRadius
        color: PanelStyle.fillSubtle
        clip: true

        ColumnLayout {
            anchors.centerIn: parent
            spacing: Tokens.space.none

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 5

                Glyph { text: pill.glyph; font.pixelSize: 14 }

                Text {
                    text: pill.value
                    font.family: PanelStyle.fontFamily
                    font.pixelSize: 13
                    font.bold: true
                    color: Theme.on_surface
                }
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: pill.caption
                font.family: PanelStyle.fontFamily
                font.pixelSize: 9
                color: Theme.outline
            }
        }
    }

    // A small selectable pill - the Mpris player switcher. There is no
    // existing "selected" style to reuse here (DeviceRow's radio-dot list
    // lives in AudioWindow.qml and is full-width, which a row of these isn't),
    // so this is a filled-vs-outlined pill instead, in the same accent-fill
    // language ToolTile already uses for its active state.
    component PlayerChip: Rectangle {
        id: chip
        required property string label
        required property bool active
        signal picked

        implicitHeight: 22
        implicitWidth: Math.min(chipText.implicitWidth, 90) + 18
        radius: PanelStyle.chipRadius
        color: chip.active ? Theme.primary
                            : chipMouse.containsMouse
                              ? PanelStyle.fillHover
                              : PanelStyle.fillSubtle
        border.width: chip.active ? 0 : 1
        border.color: PanelStyle.withAlpha(PanelStyle.textMuted, Tokens.opacity.panelBorder)
        Behavior on color { ColorAnimation { duration: PanelStyle.animNormal } }

        Text {
            id: chipText
            anchors.fill: parent
            anchors.margins: Tokens.space.md
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            text: chip.label
            font.family: PanelStyle.fontFamily
            font.pixelSize: 10
            color: chip.active ? Theme.on_primary : Theme.on_surface
            elide: Text.ElideRight
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.picked()
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
            blur: PanelStyle.shadowBlur
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
            anchors.fill: parent
            anchors.margins: PanelStyle.panelPadding
            spacing: PanelStyle.panelSpacing

            // --- HEADER ---
            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.space.lg

                ColumnLayout {
                    spacing: Tokens.space.none

                    Text {
                        text: Qt.formatDateTime(clock.now, "dddd")
                        font.family: PanelStyle.fontFamily
                        font.pixelSize: 16
                        font.bold: true
                        color: Theme.primary
                    }

                    Text {
                        text: Qt.formatDateTime(clock.now, "d MMMM yyyy  ·  HH:mm")
                        font.family: PanelStyle.fontFamily
                        font.pixelSize: 11
                        color: Theme.outline
                    }
                }

                // An explicit spacer rather than fillWidth on the date column. The
                // date column had it, but a ColumnLayout whose children are plain
                // Text still reports a small implicit width, and the power button
                // ended up parked next to the date in the middle of the header
                // instead of in the corner. A zero-size filler is unambiguous.
                Item { Layout.fillWidth: true }

                // --- WEATHER ---
                // Header-sized on purpose: condition glyph and temperature only, with
                // everything else - feels-like, humidity, wind, UV and the three-day
                // outlook - in the tooltip. This sits between the date and the power
                // button, so it has to stay narrow enough not to push power off the
                // corner on a long location name.
                Rectangle {
                    id: weatherChip
                    visible: !!root.weather.temp
                    implicitWidth: weatherRow.implicitWidth + 16
                    implicitHeight: 30
                    radius: PanelStyle.buttonRadius
                    color: weatherMouse.containsMouse
                           ? PanelStyle.fillHover
                           : "transparent"

                    ToolTip.visible: weatherMouse.containsMouse
                    ToolTip.delay: 300
                    ToolTip.text: {
                        const w = root.weather
                        if (!w.temp) return ""
                        let lines = []
                        if (w.location) lines.push(w.location)
                        lines.push(w.desc + " · feels like " + w.feels + "°C")
                        lines.push("Humidity " + w.humidity + "%  ·  Wind "
                                   + w.wind + " km/h " + w.wind_dir
                                   + "  ·  UV " + w.uv)
                        if (w.days && w.days.length) {
                            lines.push("")
                            for (let i = 0; i < w.days.length; i++) {
                                const d = w.days[i]
                                const when = i === 0 ? "Today"
                                           : Qt.formatDate(new Date(d.date), "ddd")
                                lines.push(when + "   " + d.min + "–" + d.max
                                           + "°C   " + d.desc)
                            }
                        }
                        // Shown greyed with the reason attached rather than blanked:
                        // a stale reading still beats an empty header.
                        if (w.error) lines.push("\nStale — " + w.error)
                        lines.push("\nClick to refresh")
                        return lines.join("\n")
                    }

                    RowLayout {
                        id: weatherRow
                        anchors.centerIn: parent
                        spacing: 5

                        Glyph {
                            text: root.weather.icon ? root.weather.icon : "cloud"
                            font.pixelSize: 17
                            color: root.weather.error ? Theme.outline : Theme.primary
                        }

                        Text {
                            text: root.weather.temp ? root.weather.temp + "°" : ""
                            font.family: PanelStyle.fontFamily
                            font.pixelSize: 13
                            font.bold: true
                            color: root.weather.error ? Theme.outline : Theme.on_surface
                        }
                    }

                    MouseArea {
                        id: weatherMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.refreshWeather()
                    }
                }

                Rectangle {
                    implicitWidth: 30
                    implicitHeight: 30
                    radius: PanelStyle.buttonRadius
                    color: powerMouse.containsMouse
                           ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, Tokens.opacity.fillHover)
                           : "transparent"

                    ToolTip.visible: powerMouse.containsMouse
                    ToolTip.text: "Lock, suspend, log out, reboot or shut down"
                    ToolTip.delay: 400

                    Glyph {
                        anchors.centerIn: parent
                        text: "power_settings_new"
                        font.pixelSize: 18
                        color: powerMouse.containsMouse ? Theme.error : Theme.primary
                    }

                    MouseArea {
                        id: powerMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.isOpen = false
                            // The "power" IPC target was served by ML4W's PowerApp,
                            // which is being deleted; hyprbar now exposes the same
                            // menu under "powermenu".
                            Quickshell.execDetached(["qs", "ipc", "call", "powermenu", "toggle"])
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Theme.primary
                opacity: Tokens.opacity.barBorder
            }

            // --- SCROLLING BODY ---
            // No ScrollView: the panel grows to fit its sections instead of
            // capping and scrolling. A control centre you have to scroll defeats
            // the point - everything in it is meant to be one glance away - and
            // the window is sized from this column's implicitHeight anyway, so
            // the two would only ever fight each other.
            ColumnLayout {
                    id: body
                    Layout.fillWidth: true
                    spacing: Tokens.space.xl

                    onImplicitHeightChanged: root.bodyHeight = implicitHeight
                    Component.onCompleted: root.bodyHeight = implicitHeight

                    // ---------- SYSTEM ----------
                    Section {
                        title: "System"
                        glyph: "monitoring"

                        StatBar {
                            label: "CPU"
                            percent: root.stats.cpu || 0
                            detail: (root.stats.cores || "?") + " cores"
                                    + (root.stats.load ? "  ·  load " + root.stats.load[0] : "")
                        }

                        StatBar {
                            label: "Memory"
                            percent: root.stats.memory ? root.stats.memory.percent : 0
                            detail: root.stats.memory
                                    ? root.humanBytes(root.stats.memory.used) + " / "
                                      + root.humanBytes(root.stats.memory.total)
                                    : ""
                        }

                        StatBar {
                            label: "Disk"
                            percent: root.stats.disk ? root.stats.disk.percent : 0
                            detail: root.stats.disk
                                    ? root.humanBytes(root.stats.disk.used) + " / "
                                      + root.humanBytes(root.stats.disk.total)
                                    : ""
                        }

                        StatBar {
                            // Coerced: before the first stats read `memory` is
                            // undefined, and `undefined && ...` is undefined,
                            // which is not assignable to a bool.
                            visible: !!(root.stats.memory && root.stats.memory.swap_total > 0)
                            label: "Swap"
                            percent: root.stats.memory ? root.stats.memory.swap_percent : 0
                            detail: root.stats.memory
                                    ? root.humanBytes(root.stats.memory.swap_used) : ""
                        }

                        // Four per row. Down/Up moved to the Network menu
                        // (they're throughput readouts, not system stats), so
                        // Temp/Uptime/Fan1/Fan2 are the whole set now and all
                        // four fit one row without a rate string forcing a
                        // narrower grid.
                        GridLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Tokens.space.xs
                            columns: 4
                            rowSpacing: Tokens.space.xs
                            columnSpacing: Tokens.space.xs

                            InfoPill {
                                glyph: "device_thermostat"
                                value: root.stats.temperature ? root.stats.temperature + "°C" : "—"
                                caption: "Temp"
                            }

                            InfoPill {
                                glyph: "schedule"
                                value: root.humanUptime(root.stats.uptime)
                                caption: "Uptime"
                            }

                            // One pill per physical fan. lm-sensors reports both
                            // on this machine; a laptop with one gets one pill
                            // and a fanless one gets none.
                            Repeater {
                                model: root.stats.fans || []

                                InfoPill {
                                    required property var modelData
                                    // "toys" is a pinwheel - Material Icons Round has no fan glyph
                                    glyph: "toys"
                                    value: modelData.rpm + " rpm"
                                    caption: modelData.label
                                }
                            }
                        }
                    }

                    // ---------- DISPLAY ----------
                    Section {
                        title: "Display"
                        glyph: "brightness_6"

                        BrightnessRow {
                            visible: !!(root.brightness.internal)
                            glyph: "brightness_low"
                            label: "Internal"
                            hint: "Laptop panel backlight"
                            percent: root.brightness.internal
                                     ? root.brightness.internal.percent : 0
                            onMoved: value => root.setBrightness("internal", value)
                        }

                        BrightnessRow {
                            visible: !!(root.brightness.external)
                            glyph: "desktop_windows"
                            label: "External"
                            hint: "External monitor over DDC/CI — slower to respond than the panel"
                            percent: root.brightness.external
                                     && root.brightness.external.percent !== null
                                     ? root.brightness.external.percent : 0
                            onMoved: value => root.setBrightness("external", value)
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !root.brightness.internal && !root.brightness.external
                            text: "No controllable displays found"
                            font.family: PanelStyle.fontFamily
                            font.pixelSize: 11
                            color: Theme.outline
                        }
                    }

                    // ---------- QUICK ACTIONS ----------
                    // These were the bar's group/tools drawer.
                    Section {
                        title: "Quick actions"
                        glyph: "bolt"

                        GridLayout {
                            id: quickGrid
                            Layout.fillWidth: true
                            columns: 5
                            rowSpacing: Tokens.space.xs
                            columnSpacing: Tokens.space.xs

                            // The first four are the toggles a notification
                            // panel's own buttons-grid usually carries, so the
                            // Control Center is a superset of the panel
                            // whose button it replaced on the bar.
                            ToolTile {
                                glyph: root.tool("wifi_enabled") ? "wifi" : "wifi_off"
                                label: "Wi-Fi"
                                detail: root.tool("wifi_enabled") ? "Wi-Fi" : "Wi-Fi off"
                                active: !!root.tool("wifi_enabled")
                                hint: "Toggle the Wi-Fi radio"
                                onTriggered: root.toggleAction(
                                    "nmcli radio wifi " + (root.tool("wifi_enabled") ? "off" : "on"))
                            }

                            ToolTile {
                                glyph: root.tool("bluetooth_enabled") ? "bluetooth" : "bluetooth_disabled"
                                label: "Bluetooth"
                                detail: root.tool("bluetooth_enabled") ? "Bluetooth" : "BT off"
                                active: !!root.tool("bluetooth_enabled")
                                hint: "Toggle the Bluetooth radio (rfkill)"
                                onTriggered: root.toggleAction("rfkill toggle bluetooth")
                            }

                            ToolTile {
                                glyph: root.tool("muted") ? "volume_off" : "volume_up"
                                label: "Mute"
                                detail: root.tool("muted") ? "Muted" : "Sound on"
                                active: !!root.tool("muted")
                                hint: "Mute or unmute the default output"
                                onTriggered: root.toggleAction(
                                    "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
                            }

                            ToolTile {
                                glyph: NotificationState.dnd ? "notifications_off" : "notifications"
                                label: "Do not disturb"
                                detail: NotificationState.dnd ? "DND on" : "Notify"
                                active: NotificationState.dnd
                                hint: "Silence notifications (do-not-disturb)"
                                onTriggered: NotificationState.toggleDnd()
                            }

                            ToolTile {
                                glyph: "lock"
                                label: "Lock"
                                hint: "Lock the screen now (hyprlock)"
                                onTriggered: root.launch("hyprlock")
                            }

                            ToolTile {
                                glyph: "content_paste"
                                label: "Clipboard"
                                hint: "Clipboard history (cliphist)"
                                // Used to be ML4W's ml4w-cliphist, gone with that tree.
                                // Ours is the walker-picker-over-cliphist replacement.
                                onTriggered: root.launch(
                                    Quickshell.env("HOME") + "/.config/hypr/shehan/bin/cliphist.sh")
                            }

                            ToolTile {
                                glyph: root.stats.tools && root.stats.tools.idle_inhibited
                                       ? "coffee" : "bedtime"
                                label: "Keep awake"
                                hint: "Stop the screen locking and sleeping (hypridle)"
                                detail: root.stats.tools && root.stats.tools.idle_inhibited
                                        ? "Awake" : "Auto-sleep"
                                active: !!(root.stats.tools && root.stats.tools.idle_inhibited)
                                onTriggered: root.toggleAction(
                                    Quickshell.env("HOME") + "/.config/hypr/scripts/hypridle.sh toggle")
                            }

                            ToolTile {
                                glyph: "nightlight"
                                label: "Night light"
                                hint: "Toggle the warm screen shader (hyprsunset)"
                                onTriggered: root.toggleAction(
                                    "sleep 0.3; " + Quickshell.env("HOME")
                                    + "/.config/hypr/shehan/bin/hyprsunset-toggle.sh")
                            }

                            ToolTile {
                                readonly property string profile:
                                    root.stats.tools && root.stats.tools.power_profile
                                    ? root.stats.tools.power_profile : ""
                                glyph: profile === "performance" ? "speed"
                                     : profile === "power-saver" ? "eco" : "balance"
                                label: "Power"
                                hint: "Cycle power profile: saver, balanced, performance"
                                detail: profile === "power-saver" ? "Saver"
                                      : profile === "performance" ? "Performance"
                                      : profile === "balanced" ? "Balanced" : "Power"
                                // Cycles rather than opening a menu - there are
                                // only ever three and a menu is more clicks.
                                onTriggered: {
                                    const next = profile === "power-saver" ? "balanced"
                                               : profile === "balanced" ? "performance"
                                               : "power-saver"
                                    root.toggleAction("powerprofilesctl set " + next)
                                }
                            }

                            // These three commands are lifted from ML4W's SidebarWindow.qml -
                            // only the shell commands, not the widgets, so this doesn't
                            // depend on that file surviving an ML4W update.
                            ToolTile {
                                glyph: "brightness_6"
                                label: "Theme"
                                detail: "Theme"
                                hint: "Switch between the light and dark theme"
                                // Used to be ML4W's ml4w-toggle-theme, which dies with that
                                // tree; the rescued copy lives on $PATH under its own name.
                                onTriggered: Quickshell.execDetached(
                                    ["bash", "-c", Quickshell.env("HOME") + "/.local/bin/brilliant-toggle-theme"])
                            }

                            ToolTile {
                                glyph: "colorize"
                                label: "Colour picker"
                                detail: "Pick"
                                hint: "Pick a colour from the screen"
                                onTriggered: {
                                    root.isOpen = false
                                    Quickshell.execDetached(
                                        ["bash", "-c", "brilliant-setting run apps.colorpicker"])
                                }
                            }

                            ToolTile {
                                glyph: "photo_camera"
                                label: "Screenshot"
                                detail: "Shot"
                                hint: "Take a screenshot"
                                onTriggered: {
                                    root.isOpen = false
                                    // shehan/bin/screenshot.sh, NOT the old
                                    // hypr/scripts/screenshot.sh this used to call.
                                    // That one was ML4W's: it read three settings out
                                    // of ~/.config/ml4w/settings/ and asked `rofi
                                    // -dmenu` whether to copy or save -- and rofi was
                                    // removed from the machine on 2026-08-18, so this
                                    // tile had been dead for a day before anyone
                                    // noticed. The keybinds (PRINT, SUPER+SHIFT+S...)
                                    // were already on the ported script; this was the
                                    // last caller of the old one, which is now deleted.
                                    // `region` matches SUPER+SHIFT+S -- drag a box,
                                    // saved and copied and toasted, no menu.
                                    Quickshell.execDetached(
                                        ["bash", "-c", Quickshell.env("HOME") + "/.config/hypr/shehan/bin/screenshot.sh region"])
                                }
                            }

                            ToolTile {
                                glyph: "wallpaper"
                                label: "Wallpaper"
                                detail: "Set"
                                hint: "Choose a wallpaper and re-theme the desktop"
                                onTriggered: {
                                    root.isOpen = false
                                    Quickshell.execDetached(["bash", "-c", "brilliant-wallpaper-app"])
                                }
                            }

                            // No live-state field for gamemode in stats.tools, so this
                            // tile fires-and-forgets like Night light rather than
                            // reflecting on/off like Keep awake does.
                            ToolTile {
                                glyph: "sports_esports"
                                label: "Game mode"
                                hint: "Toggle gamemode (drops effects and animations)"
                                onTriggered: root.toggleAction(
                                    Quickshell.env("HOME") + "/.config/hypr/scripts/gamemode.sh")
                            }

                            // Same as above - no stats field to bind active: to.
                            ToolTile {
                                glyph: "terminal"
                                label: "Fastfetch"
                                hint: "Show or hide fastfetch in new terminals"
                                onTriggered: root.toggleAction(
                                    Quickshell.env("HOME") + "/.config/hypr/shehan/bin/fastfetch-toggle.sh")
                            }

                            // A standalone GTK4/libadwaita app, deliberately not part of
                            // the shell - it costs nothing when closed and can grow into
                            // a control surface for the whole session later. It edits the
                            // JSON files the panels already watch, so there is no IPC.
                            ToolTile {
                                glyph: "tune"
                                label: "Settings"
                                detail: "Settings"
                                hint: "Open the Control Center settings app"
                                onTriggered: {
                                    root.isOpen = false
                                    Quickshell.execDetached(["waybar-control-center-settings"])
                                }
                            }
                        }
                    }

                    // ---------- MEDIA ----------
                    // Quickshell's Mpris service replaces the bar's `custom/nowplaying`
                    // module, which polled `playerctl` every second - the players
                    // already live on the session bus, so this reads them directly
                    // instead.
                    Section {
                        id: mediaSection
                        title: "Media"
                        glyph: "music_note"

                        // First player that is actually playing, falling back to the
                        // first player at all.
                        readonly property var autoPlayer: {
                            const players = Mpris.players.values
                            if (players.length === 0) return null
                            return players.find(p => p.isPlaying) || players[0]
                        }

                        // Sticky per session only, by identity rather than index so
                        // it survives Mpris.players.values reordering. Empty means
                        // "auto". Not persisted to disk on purpose - which player is
                        // "yours" today has nothing to do with which one was yours
                        // last restart.
                        property string pinnedIdentity: ""

                        // undefined rather than null when nothing matches, so a
                        // pinned player that has disappeared (app closed, tab
                        // closed) falls back to autoPlayer via `||` below instead
                        // of the switcher going blank.
                        readonly property var pinnedPlayer: mediaSection.pinnedIdentity !== ""
                            ? Mpris.players.values.find(p => p.identity === mediaSection.pinnedIdentity)
                            : undefined

                        readonly property var player: mediaSection.pinnedPlayer || mediaSection.autoPlayer

                        // Bumped by the Timer below so progressFraction has something
                        // to react to - MprisPlayer.position is read on access, it
                        // does not push updates on its own.
                        property int positionTick: 0

                        readonly property real progressFraction: {
                            positionTick // dependency only, see comment above
                            if (!player || !player.lengthSupported || !player.positionSupported
                                    || player.length <= 0) return 0
                            return Math.min(1, player.position / player.length)
                        }

                        // Only worth showing once there is a choice to make -
                        // with one player the auto pick is never a guess.
                        RowLayout {
                            Layout.fillWidth: true
                            visible: Mpris.players.values.length > 1
                            spacing: Tokens.space.sm

                            Repeater {
                                model: Mpris.players.values

                                PlayerChip {
                                    required property var modelData
                                    label: modelData.identity
                                    active: modelData === mediaSection.player
                                    onPicked: mediaSection.pinnedIdentity = modelData.identity
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !mediaSection.player
                            text: "Nothing playing"
                            font.family: PanelStyle.fontFamily
                            font.pixelSize: 11
                            color: Theme.outline
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !!mediaSection.player
                            spacing: Tokens.space.md

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 56
                                radius: PanelStyle.controlRadius
                                color: trackMouse.containsMouse
                                       ? PanelStyle.fillHover
                                       : "transparent"

                                RowLayout {
                                    anchors.fill: parent
                                    spacing: Tokens.space.lg

                                    Rectangle {
                                        Layout.preferredWidth: 48
                                        Layout.preferredHeight: 48
                                        radius: PanelStyle.buttonRadius
                                        color: "transparent"
                                        clip: true
                                        visible: !!(mediaSection.player && mediaSection.player.trackArtUrl)

                                        Image {
                                            anchors.fill: parent
                                            asynchronous: true
                                            fillMode: Image.PreserveAspectCrop
                                            source: mediaSection.player ? mediaSection.player.trackArtUrl : ""
                                        }
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: Tokens.space.hairline

                                        Text {
                                            Layout.fillWidth: true
                                            text: mediaSection.player ? mediaSection.player.trackTitle : ""
                                            font.family: PanelStyle.fontFamily
                                            font.pixelSize: 12
                                            font.bold: true
                                            color: Theme.on_surface
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            visible: !!(mediaSection.player && mediaSection.player.trackArtist)
                                            text: mediaSection.player ? mediaSection.player.trackArtist : ""
                                            font.family: PanelStyle.fontFamily
                                            font.pixelSize: 11
                                            color: Theme.outline
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                MouseArea {
                                    id: trackMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (mediaSection.player) mediaSection.player.raise()
                                }
                            }

                            // Read-only - the point is glanceable state, not a seek
                            // bar to drag.
                            Rectangle {
                                Layout.fillWidth: true
                                visible: !!(mediaSection.player && mediaSection.player.lengthSupported
                                            && mediaSection.player.positionSupported
                                            && mediaSection.player.length > 0)
                                implicitHeight: 3
                                radius: Tokens.radius.full
                                color: PanelStyle.fillTrack

                                Rectangle {
                                    width: parent.width * mediaSection.progressFraction
                                    height: parent.height
                                    radius: parent.radius
                                    color: Theme.primary
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignHCenter
                                spacing: 24

                                Glyph {
                                    text: "skip_previous"
                                    font.pixelSize: 20
                                    opacity: mediaSection.player && mediaSection.player.canGoPrevious ? 1 : 0.35

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: !!(mediaSection.player && mediaSection.player.canGoPrevious)
                                        onClicked: mediaSection.player.previous()
                                    }
                                }

                                Glyph {
                                    text: mediaSection.player && mediaSection.player.isPlaying
                                          ? "pause" : "play_arrow"
                                    font.pixelSize: 22
                                    opacity: mediaSection.player && mediaSection.player.canTogglePlaying ? 1 : 0.35

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: !!(mediaSection.player && mediaSection.player.canTogglePlaying)
                                        onClicked: mediaSection.player.togglePlaying()
                                    }
                                }

                                Glyph {
                                    text: "skip_next"
                                    font.pixelSize: 20
                                    opacity: mediaSection.player && mediaSection.player.canGoNext ? 1 : 0.35

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        enabled: !!(mediaSection.player && mediaSection.player.canGoNext)
                                        onClicked: mediaSection.player.next()
                                    }
                                }
                            }
                        }

                        // Runs only while there is something to watch tick over -
                        // expanded and playing - so a paused or idle player does not
                        // spend a timer on a bar that never moves.
                        Timer {
                            interval: 1000
                            repeat: true
                            running: !mediaSection.collapsed
                                     && !!(mediaSection.player && mediaSection.player.isPlaying)
                            onTriggered: mediaSection.positionTick++
                        }
                    }

                    // ---------- NOTIFICATIONS ----------
                    // Quickshell is the notification daemon now, so there is no
                    // separate process to front for. This section is just a
                    // summary of what NotificationState is holding, and a way
                    // into the panel it owns.
                    Section {
                        title: "Notifications"
                        glyph: "notifications"

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 44
                            radius: PanelStyle.controlRadius
                            color: notifMouse.containsMouse
                                   ? PanelStyle.fillHover
                                   : PanelStyle.fillSubtle

                            ToolTip.visible: notifMouse.containsMouse
                            ToolTip.text: "Open the notification panel"
                            ToolTip.delay: 400

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Tokens.space.xl
                                anchors.rightMargin: Tokens.space.xl
                                spacing: Tokens.space.lg

                                Glyph {
                                    text: NotificationState.dnd ? "notifications_off"
                                        : NotificationState.count > 0 ? "notifications_active"
                                        : "notifications_none"
                                    font.pixelSize: 18
                                    color: NotificationState.dnd ? Theme.outline
                                         : NotificationState.count > 0 ? Theme.tertiary
                                         : Theme.primary
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: {
                                        const n = NotificationState.count || 0
                                        if (n === 0) return NotificationState.dnd
                                                     ? "No notifications · DND on" : "No notifications"
                                        return n + " notification" + (n === 1 ? "" : "s")
                                               + (NotificationState.dnd ? " · DND on" : "")
                                    }
                                    font.family: PanelStyle.fontFamily
                                    font.pixelSize: 12
                                    color: Theme.on_surface
                                }

                                Glyph { text: "chevron_right"; font.pixelSize: 16; color: Theme.outline }
                            }

                            MouseArea {
                                id: notifMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.isOpen = false
                                    NotificationState.togglePanel()
                                }
                            }
                        }
                    }

                    // ---------- UPDATES ----------
                    Section {
                        title: "Updates"
                        glyph: "system_update_alt"

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 44
                            radius: PanelStyle.controlRadius
                            color: updatesMouse.containsMouse
                                   ? PanelStyle.fillHover
                                   : PanelStyle.fillSubtle

                            ToolTip.visible: updatesMouse.containsMouse && root.updateCount > 0
                            ToolTip.text: "Install pending package updates"
                            ToolTip.delay: 400

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Tokens.space.xl
                                anchors.rightMargin: Tokens.space.xl
                                spacing: Tokens.space.lg

                                Glyph {
                                    text: root.updateCount > 0 ? "download_for_offline" : "check_circle"
                                    font.pixelSize: 18
                                    color: root.updateCount > 0 ? Theme.tertiary : Theme.primary
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.updateCount > 0
                                          ? root.updateCount + " package" + (root.updateCount === 1 ? "" : "s")
                                            + " to update"
                                          : "System is up to date"
                                    font.family: PanelStyle.fontFamily
                                    font.pixelSize: 12
                                    color: Theme.on_surface
                                }

                                Glyph {
                                    text: "chevron_right"
                                    font.pixelSize: 16
                                    color: Theme.outline
                                    visible: root.updateCount > 0
                                }
                            }

                            MouseArea {
                                id: updatesMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: root.updateCount > 0
                                onClicked: root.launch(root.updateCommand)
                            }
                        }

                    }

                    // ---------- TRAY ----------
                    Section {
                        title: "Tray"
                        glyph: "widgets"

                        Text {
                            Layout.fillWidth: true
                            visible: SystemTray.items.values.length === 0
                            text: "Nothing in the tray"
                            font.family: PanelStyle.fontFamily
                            font.pixelSize: 11
                            color: Theme.outline
                        }

                        Repeater {
                            id: trayRepeater
                            model: SystemTray.items

                            // display() hands the entry list to the compositor as a
                            // second surface. That surface takes focus, the panel's
                            // HyprlandFocusGrab sees focus leave, and onCleared closes
                            // the whole panel out from under the menu - indistinguishable
                            // from the click doing nothing. Tracking the open item here
                            // instead and rendering the entries as ordinary rows keeps
                            // everything on the one surface the grab already owns.
                            property var openItem: null

                            ColumnLayout {
                                id: trayRow
                                required property var modelData
                                readonly property bool menuOpen: trayRepeater.openItem === trayRow.modelData

                                Layout.fillWidth: true
                                spacing: Tokens.space.xs

                                // Resolves the item's menu handle into a flat list of
                                // QsMenuEntry children. Kept bound regardless of menuOpen
                                // so the entries are already there the moment a row
                                // expands instead of popping in a frame late.
                                QsMenuOpener {
                                    id: menuOpener
                                    menu: trayRow.modelData.menu
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 38
                                    radius: PanelStyle.buttonRadius
                                    color: trayMouse.containsMouse
                                           ? PanelStyle.fillHover
                                           : "transparent"

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Tokens.space.sm
                                        anchors.rightMargin: Tokens.space.sm
                                        spacing: Tokens.space.lg

                                        Image {
                                            source: trayRow.modelData.icon
                                            sourceSize.width: 20
                                            sourceSize.height: 20
                                            width: 20
                                            height: 20
                                            fillMode: Image.PreserveAspectFit
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: trayRow.modelData.tooltipTitle
                                                  || trayRow.modelData.title
                                                  || trayRow.modelData.id
                                            font.family: PanelStyle.fontFamily
                                            font.pixelSize: 12
                                            color: Theme.on_surface
                                            elide: Text.ElideRight
                                        }

                                        Glyph {
                                            text: "more_vert"
                                            font.pixelSize: 16
                                            // Same glyph either way - open state reads
                                            // through its color rather than swapping the
                                            // icon, so the affordance does not jump around.
                                            color: trayRow.menuOpen ? Theme.primary : Theme.outline
                                            visible: trayRow.modelData.hasMenu
                                        }
                                    }

                                    MouseArea {
                                        id: trayMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: mouse => {
                                            // An item with onlyMenu has no activate
                                            // action at all - left-clicking it in a
                                            // real tray opens the menu too.
                                            if (mouse.button === Qt.RightButton
                                                    || trayRow.modelData.onlyMenu) {
                                                if (trayRow.modelData.hasMenu) {
                                                    trayRepeater.openItem = trayRow.menuOpen
                                                        ? null : trayRow.modelData
                                                }
                                            } else {
                                                // Fire and stay open. Plenty of items
                                                // do not implement Activate at all -
                                                // Spotify's Ayatana indicator answers
                                                // "No handler for Activate" and does not
                                                // set ItemIsMenu either, so `onlyMenu` is
                                                // false and nothing warns us up front.
                                                // Closing the panel on that no-op left
                                                // the user staring at a shut panel with
                                                // nothing having happened; staying open
                                                // costs a working item one Escape and
                                                // keeps the menu one right-click away.
                                                trayRow.modelData.activate()
                                            }
                                        }
                                    }
                                }

                                // The inline menu itself. Sits in the row's own place in
                                // the layout, so it pushes everything below it down
                                // rather than floating over it.
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 14
                                    spacing: Tokens.space.none
                                    visible: trayRow.menuOpen

                                    Repeater {
                                        model: trayRow.menuOpen ? menuOpener.children : null

                                        Rectangle {
                                            id: entryRow
                                            required property var modelData

                                            Layout.fillWidth: true
                                            implicitHeight: entryRow.modelData.isSeparator ? 9 : 30
                                            radius: PanelStyle.buttonRadius
                                            color: entryMouse.containsMouse
                                                   ? PanelStyle.fillHover
                                                   : "transparent"

                                            // A separator carries no text - a hairline
                                            // stands in for the row instead.
                                            Rectangle {
                                                visible: entryRow.modelData.isSeparator
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                implicitHeight: 1
                                                color: Theme.outline_variant
                                            }

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: Tokens.space.sm
                                                anchors.rightMargin: Tokens.space.sm
                                                spacing: Tokens.space.md
                                                visible: !entryRow.modelData.isSeparator

                                                Image {
                                                    source: entryRow.modelData.icon || ""
                                                    visible: !!entryRow.modelData.icon
                                                    sourceSize.width: 16
                                                    sourceSize.height: 16
                                                    width: 16
                                                    height: 16
                                                    fillMode: Image.PreserveAspectFit
                                                    opacity: entryRow.modelData.enabled ? 1 : 0.4
                                                }

                                                Text {
                                                    Layout.fillWidth: true
                                                    text: entryRow.modelData.text
                                                    font.family: PanelStyle.fontFamily
                                                    font.pixelSize: 12
                                                    color: Theme.on_surface
                                                    opacity: entryRow.modelData.enabled ? 1 : 0.4
                                                    elide: Text.ElideRight
                                                }

                                                // Submenus are not walked here - hasChildren
                                                // just gets a marker rather than a working
                                                // descent. Doing that properly means another
                                                // level of QsMenuOpener plus its own open/close
                                                // state, which is more than a small addition;
                                                // flagged in the report instead of guessed at.
                                                Glyph {
                                                    text: "chevron_right"
                                                    font.pixelSize: 14
                                                    color: Theme.outline
                                                    visible: entryRow.modelData.hasChildren
                                                }
                                            }

                                            MouseArea {
                                                id: entryMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                enabled: !entryRow.modelData.isSeparator
                                                         && entryRow.modelData.enabled
                                                onClicked: {
                                                    // QsMenuEntry has no callable "activate" -
                                                    // triggered is a plain signal, and calling
                                                    // a signal like a method is how QML emits
                                                    // it. That emission is what the compositor
                                                    // is actually listening for.
                                                    entryRow.modelData.triggered()
                                                    trayRepeater.openItem = null
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
            }
        }
    }

    // Drives the header clock. One second would be wasted work for a display
    // that only shows minutes.
    Timer {
        id: clock
        property date now: new Date()
        interval: 20000
        repeat: true
        running: root.isOpen
        triggeredOnStart: true
        onTriggered: now = new Date()
    }
}
