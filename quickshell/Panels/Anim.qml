// Typed motion roles, on top of PanelStyle's duration roles.
//
// PanelStyle already names four duration roles (animFast/Normal/Slow/Slower,
// PanelStyle.qml:232-235), each a settings-backed alias for
// Tokens.motion.duration.*. Nothing in this repo pairs those with
// Tokens.motion.easing's M3 cubic-bezier curves yet -- every animation still
// hardcodes a Qt built-in curve (Easing.OutQuad, ...) next to a PanelStyle
// duration. This component is the first real consumer of the easing tokens.
//
// From the caelestia teardown's `Anim { type: Anim.EmphasizedLarge }` idea
// (09-caelestia-teardown.md §2.1), adapted for plain QML: a named `role`
// instead of a duration+easing pair, so restyling all motion is a data edit
// in tokens.json instead of a grep-and-replace across files.
//
// DELIBERATELY NOT WIRED IN. This is a new, opt-in primitive -- nothing in
// the repo uses it yet. Picking the first real call site to convert needs
// someone who can see the animation live, which this session cannot do.
import QtQuick
import qs.CustomTheme
import qs.Panels

NumberAnimation {
    id: root

    // One of: "fast" (hover recolours), "normal" (state changes, switches),
    // "slow" (a value physically moving), "slower" (a whole panel sliding
    // open/closed) -- matching PanelStyle's own duration-role comments --
    // crossed with an M3 easing family: "standard", "decelerate" (entrances),
    // "accelerate" (exits), "emphasized" (state changes that should draw the
    // eye).
    property string duration_: "normal"
    property string easing_: "standard"

    function _bezier(curve: var): var {
        // tokens.json stores [x1, y1, x2, y2]; QML's bezierCurve wants
        // control1, control2, endpoint -- a single cubic ends at (1, 1).
        return [curve[0], curve[1], curve[2], curve[3], 1.0, 1.0]
    }

    readonly property var _durations: ({
        fast: PanelStyle.animFast,
        normal: PanelStyle.animNormal,
        slow: PanelStyle.animSlow,
        slower: PanelStyle.animSlower
    })

    // No manual motion.enabled check needed -- PanelStyle's anim* roles are
    // themselves Tokens.motion.duration.*, already switched to 0 in game
    // mode. Reading through them gets that for free.
    duration: root._durations[root.duration_]
    easing.type: Easing.BezierSpline
    easing.bezierCurve: root._bezier(Tokens.motion.easing[root.easing_])
}
