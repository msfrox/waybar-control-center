// The bar. Replaces Waybar; see PLAN.md phase 10 for why.
//
// The short version: seven of Waybar's sixteen modules here were buttons whose whole
// job was `qs ipc call`, and the Claude dial was a PNG rendered to disk every 60s
// because Waybar cannot draw an arc. Keeping a second toolkit, a second theme system
// and a second config language for that stopped making sense.
//
// This is OUR bar, not ML4W's `StatusbarApp`. That one is real code and good donor
// material, but it is a centred pill with a different design intent, it lacks most of
// what this bar shows, and it lives on the ML4W clobber list in
// docs/quickshell-patches.md — the last place to put the most important file.
//
// LAYOUT mirrors Waybar's three boxes exactly: left pinned left, centre pinned to the
// screen centre (not to the space left over by the other two), right pinned right.
// That means the centre group can overlap the others if it grows too wide — which is
// also true of Waybar, and is why the taskbar there has an icon budget.
//
// Waybar stays installed. ML4W's own switch (~/.config/ml4w/settings/statusbar plus
// the waybar-disabled sentinel that ~/.config/waybar/launch.sh honours) flips between
// the two on SUPER+CTRL+B, so this can be developed and abandoned freely.

import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import qs.CustomTheme

Scope {
    id: root

    // --- SETTINGS ---
    // Owned by this repo, edited by hyprsys, exactly like every other panel here:
    // the file is the contract and nothing has to talk to the running shell.
    property bool barEnabled: settings.enabled
    property int barHeight: settings.height

    // "top" while Waybar still owns the bottom edge, so both can run side by side
    // and be compared directly during the build. Flips to "bottom" at cutover
    // (phase 10 step 6) — at which point this is a real user setting, since Waybar
    // had one too.
    property string barPosition: settings.position

    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/waybar-control-center/bar.json"
        watchChanges: true
        onFileChanged: reload()

        // No file yet is the normal first-run case, not an error — every value
        // below already carries the default that reproduces the Waybar setup.
        onLoadFailed: (error) => {}

        JsonAdapter {
            id: settings
            property bool enabled: true
            property string position: "top"
            // 52px is what Waybar reserved here (hyprctl monitors -j -> reserved[3]),
            // so windows tile to exactly the same place across the cutover.
            property int height: 52
        }
    }

    IpcHandler {
        target: "bar"
        function toggle(): void { root.setEnabled(!root.barEnabled) }
        function show(): void { root.setEnabled(true) }
        function hide(): void { root.setEnabled(false) }
        function isEnabled(): bool { return root.barEnabled }
        function reload(): void { settingsFile.reload() }
    }

    function setEnabled(on: bool): void {
        settings.enabled = on
        settingsFile.writeAdapter()
    }

    // --- LAUNCHING THINGS ---
    // Waybar's on-click values are shell strings, so the ones carried over verbatim
    // keep going through sh. Anything this repo owns is exec'd directly.
    function sh(command: string): void {
        Quickshell.execDetached(["sh", "-c", command])
    }

    // Opening a sibling panel still goes out through `qs ipc call` rather than
    // calling into it, even though both now live in this process. It is a process
    // spawn per click, which is worth replacing with an in-process signal bus once
    // the panels are being touched anyway — but doing it now would mean editing five
    // panel files for a change that has no user-visible effect, and it would lose the
    // property that every trigger behaves identically to the Waybar one it replaces.
    function panel(target: string, method: string): void {
        Quickshell.execDetached(["qs", "ipc", "call", target, method])
    }

    Variants {
        // One bar per screen. Only eDP-1 exists on this machine, so this is
        // insurance rather than a feature — but it is insurance worth having up
        // front, because retrofitting it means rewriting the root object. ML4W's
        // StatusbarApp is a single PanelWindow and would need exactly that.
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            visible: root.barEnabled
            // Top, not Overlay: the panels this bar opens are Overlay and must draw
            // above it, which is also how Waybar and the panels related.
            WlrLayershell.layer: WlrLayer.Top

            // No explicit exclusiveZone. Anchored to three edges with a fixed
            // implicitHeight, the default Auto exclusion mode reserves exactly the
            // bar's height, and hiding the window releases it for free.
            implicitHeight: root.barHeight
            color: "transparent"

            anchors {
                left: true
                right: true
                top: root.barPosition === "top"
                bottom: root.barPosition !== "top"
            }

            // ONE rectangle with a translucent fill. Never a gradient: a QML gradient
            // is a fill, not a border, so anything inset inside it composites against
            // the gradient instead of the wallpaper. That bug made every card in this
            // repo opaque for months — see HANDOFF.md.
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(Theme.background.r, Theme.background.g,
                               Theme.background.b, 0.6)
            }

            // --- MODULE GROUPS ---
            // Margins match the Waybar CSS: .modules-left has 8px on the left,
            // .modules-right 8px on the right, centre none.

            RowLayout {
                id: leftGroup
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                // Waybar's config sets `spacing: 0` and does all module gaps with
                // per-module CSS margins. Matching that keeps BarButton.rightMargin
                // the single place a gap is expressed.
                spacing: 0

                // Step 2 fills this: workspaces, quicklinks, nowplaying, window title.
            }

            RowLayout {
                id: centerGroup
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                // Waybar's config sets `spacing: 0` and does all module gaps with
                // per-module CSS margins. Matching that keeps BarButton.rightMargin
                // the single place a gap is expressed.
                spacing: 0

                BarButton {
                    glyph: "apps"
                    // Waybar: on-click waybar-app-launcher-toggle, middle rofi,
                    // right the keybindings cheatsheet.
                    onClicked: root.sh("waybar-app-launcher-toggle")
                    onMiddleClicked: root.sh("rofi -show drun -replace")
                    onRightClicked: root.sh(
                        Quickshell.env("HOME") + "/.config/ml4w/scripts/keybindings.sh")
                }

                // Step 3 adds the grouped taskbar here.
            }

            RowLayout {
                id: rightGroup
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                // Waybar's config sets `spacing: 0` and does all module gaps with
                // per-module CSS margins. Matching that keeps BarButton.rightMargin
                // the single place a gap is expressed.
                spacing: 0

                // Step 2 inserts the volume / Bluetooth / network / battery
                // indicators ahead of these, and step 5 the Claude dial.

                BarButton {
                    glyph: "dashboard"
                    rightMargin: 13
                    onClicked: root.panel("control-center", "toggle")
                }

                BarButton {
                    // ML4W's sidebar / welcome pair. Not a glyph at all: the Waybar
                    // module's format is a single space and the logo arrives as a CSS
                    // background-image, which is why porting the "icon" across as text
                    // produced an invisible button.
                    iconSource: "file://" + Quickshell.env("HOME")
                                + "/.config/waybar/assets/ml4w-icon-white.svg"
                    rightMargin: 12
                    onClicked: root.panel("sidebar", "toggle")
                    onRightClicked: root.panel("welcome", "toggle")
                }

                ClockModule {
                    onClicked: root.panel("notifications", "toggle")
                }
            }
        }
    }
}
