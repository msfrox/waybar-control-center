// Port of Waybar's `bluetooth` module (see ~/.config/waybar/modules.json). Verbatim
// behaviour, glyphs named rather than quoted raw so nothing private-use ends up
// pasted into this file:
//
//     format               = <bluetooth-b glyph> " " {status}
//     format-connected     = <bluetooth-b glyph> " " <check mark>
//     format-disabled      = ""
//     format-off           = ""
//     format-no-controller = ""
//
// THE SURPRISING PART: an empty Waybar format string does not render blank, it
// HIDES the module - Waybar removes it from the bar entirely and every other
// module shifts to close the gap. format-disabled, format-off and
// format-no-controller are all empty, so "no adapter", "adapter off" and
// "adapter disabled" are three different Waybar states that all look like the
// module was never installed. `visible: bt.adapterEnabled` below is the port of
// that - QtQuick Layouts already excludes an invisible item from a RowLayout's
// size calculation, same as Waybar dropping the module from its box.
//
// Glyphs are written as \uXXXX escapes, never pasted as literal characters, and
// resolved through BarButton.labelFamilies (Font Awesome Brands carries
// bluetooth-b). The check mark is plain Unicode, not Font Awesome, but gets the
// same \uXXXX treatment for consistency.
import Quickshell
import Quickshell.Bluetooth
import QtQuick
import qs.CustomTheme

BarButton {
    id: bt

    labelSize: 16
    rightMargin: 14

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool adapterEnabled: bt.adapter !== null && bt.adapter.enabled
    readonly property var connectedDevices: Bluetooth.devices
        ? Bluetooth.devices.values.filter(d => d.connected) : []

    // No adapter / off / disabled all collapse to "not on the bar", matching
    // Waybar's three empty formats above.
    visible: bt.adapterEnabled

    label: bt.connectedDevices.length > 0
        // format-connected: at least one device connected, so the on/off
        // status stops mattering.
        ? "\uf293 \u2713"   // bluetooth-b (FA Brands), check mark
        // format with Waybar's {status} substituted - the only status string
        // reachable here is "on", since "off"/"disabled" are hidden above.
        : "\uf293 on"       // bluetooth-b (FA Brands)

    // #bluetooth.disabled / .off in the Waybar CSS is 45% alpha of the normal
    // colour. Both states hide the module (visible: false, above), so this
    // branch can never actually paint - kept because it costs nothing and
    // documents what the CSS says, in case `visible` is ever loosened later.
    contentColor: bt.hovered
        ? Theme.primary
        : (bt.adapterEnabled
           ? Theme.on_surface
           : Qt.rgba(Theme.on_surface.r, Theme.on_surface.g, Theme.on_surface.b, 0.45))

    Behavior on contentColor {
        ColorAnimation { duration: 300; easing.type: Easing.OutQuad }
    }

    onClicked: Quickshell.execDetached(["qs", "ipc", "call", "bluetooth", "toggle"])
    // Compound command with a `~` in it, so it has to go through a shell same
    // as Waybar's on-click-right does.
    onRightClicked: Quickshell.execDetached(
        ["sh", "-c", "sleep 0.1 && ~/.config/ml4w/settings/bluetooth.sh"])
}
