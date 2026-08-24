// A Loader wrapper that animates its own content swaps: fade the current
// item out, swap the underlying `Loader.sourceComponent`, fade the new item
// in. Content changes are animated BY CONSTRUCTION — no call site has to
// remember a `Behavior` of its own. Ported from caelestia's `AnimLoader`
// (brilliant repo docs/09-caelestia-teardown.md §2.2); nothing in this repo
// uses it yet, panels still hard-cut between states, and picking the first
// real adoption site is a deliberate follow-up, not this change.
//
//     AnimLoader {
//         sourceComponent: root.expanded ? expandedView : collapsedView
//     }
//
// Swap speed is `PanelStyle.animFast` — the shortest role, because a content
// swap should read as instant-but-smooth rather than a transition anyone
// waits on. Collapses to a plain, unanimated swap when `Tokens.motion.enabled`
// is false, the same game-mode switch every other duration in `PanelStyle`
// answers to (see `Tokens.motion.duration.slower` in ClaudeUsageWindow.qml
// for the precedent of reading `Tokens` directly alongside `PanelStyle`).

import QtQuick
import qs.CustomTheme
import qs.Panels

Item {
    id: animLoader

    property Component sourceComponent
    readonly property alias item: loader.item
    readonly property alias status: loader.status

    // False until the first Component swap has happened, so that initial
    // assignment (fired while properties are still being set, before
    // Component.onCompleted) lands instantly rather than fading in from
    // nothing.
    property bool ready: false

    implicitWidth: loader.implicitWidth
    implicitHeight: loader.implicitHeight

    onSourceComponentChanged: {
        if (!animLoader.ready)
            return
        if (!Tokens.motion.enabled) {
            loader.sourceComponent = animLoader.sourceComponent
            return
        }
        swap.restart()
    }

    Component.onCompleted: {
        loader.sourceComponent = animLoader.sourceComponent
        animLoader.ready = true
    }

    Loader {
        id: loader
        anchors.fill: parent
        asynchronous: true
    }

    SequentialAnimation {
        id: swap

        NumberAnimation {
            target: loader
            property: "opacity"
            to: 0
            duration: PanelStyle.animFast
            easing.type: Easing.OutCubic
        }
        ScriptAction { script: loader.sourceComponent = animLoader.sourceComponent }
        NumberAnimation {
            target: loader
            property: "opacity"
            to: 1
            duration: PanelStyle.animFast
            easing.type: Easing.OutCubic
        }
    }
}
