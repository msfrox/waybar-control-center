// Port of Waybar's `network` module (see ~/.config/waybar/modules.json). Verbatim
// behaviour, glyphs named rather than quoted raw so nothing private-use ends up
// pasted into this file:
//
//     format               = {ifname}                              (unused, see below)
//     format-wifi          = <wifi glyph> " " {signalStrength} "%"
//     format-ethernet      = <network-wired glyph> "  " {ifname}
//     format-disconnected  = <xmark glyph> " " <warning sign>
//     max-length: 50
//
// `format` (bare ifname, no icon) is Waybar's fallback for NetworkManager device
// states this port doesn't model - e.g. a device mid-"linking" before it is fully
// up or down. Quickshell.Networking's device model only distinguishes connected
// wifi / connected wired / neither, which format-wifi, format-ethernet and
// format-disconnected already cover completely, so `format` is never reached
// here and isn't implemented.
//
// PRIMARY-CONNECTION PREFERENCE, WIFI VS WIRED: this machine has no ethernet
// device at all (`nmcli device status` - only wlan0, tailscale0 and bridges), so
// there was nothing to observe Waybar preferring when both are up. Defaulted to
// preferring wired, matching NetworkManager's own default route metrics (wired
// connections get a lower/better metric than wifi, so libnm's "primary
// connection" - what Waybar's network module reads - normally resolves to wired
// when both are active). Revisit this if this machine ever gets a wired
// connection and Waybar visibly disagrees.
//
// SIGNAL STRENGTH SCALE - VERIFIED, NOT ASSUMED: Quickshell.Networking's
// WifiNetwork.signalStrength is a 0..1 double, not a 0..100 percentage. Checked
// live: a throwaway `qs -p` script logged `signalStrength= 0.44` off
// `Networking.devices` for the connected SSID at the same moment
// `nmcli -t -f active,signal,ssid dev wifi list --rescan no` printed
// `yes:44:TecRoot 5G` (and the NetworkManager D-Bus AccessPoint.Strength
// property, which is the 0-100 byte Waybar's own network module reads, agreed:
// `44`). So `Math.round(signalStrength * 100)` is the one correct scaling, and
// is what makes this module read the same number the bottom Waybar shows.
//
// Glyphs are written as \uXXXX escapes, never pasted as literal characters, and
// resolved through BarButton.labelFamilies. wifi and xmark are FA Free; the
// warning sign is plain Unicode but gets the same treatment for consistency.
import Quickshell
import Quickshell.Networking
import QtQuick
import qs.CustomTheme

BarButton {
    id: net

    labelSize: 16
    rightMargin: 14

    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property var wiredConnected:
        net.devices.find(d => d.type === DeviceType.Wired && d.connected) || null
    readonly property var wifiDevice:
        net.devices.find(d => d.type === DeviceType.Wifi) || null
    readonly property bool wifiConnected:
        net.wifiDevice !== null && net.wifiDevice.connected
    readonly property var activeWifiNetwork: {
        if (!net.wifiDevice || !net.wifiDevice.networks) return null
        return net.wifiDevice.networks.values.find(n => n.connected) || null
    }
    readonly property bool disconnected: !net.wiredConnected && !net.wifiConnected

    label: {
        let raw
        if (net.wiredConnected) {
            // format-ethernet: network-wired glyph, TWO spaces, ifname.
            // U+F796 network-wired, exactly as modules.json has it. It is one of the
            // four glyphs that exist only in Font Awesome 7 Free's Solid-900 face, so
            // it renders only because BarButton asks for weight 900 on icon runs.
            raw = "\uf796  " + net.wiredConnected.name
        } else if (net.wifiConnected) {
            // format-wifi: wifi glyph, ONE space, integer percentage.
            // signalStrength is 0..1 - see the header note on how that was
            // confirmed - so it has to be scaled to match Waybar's percentage.
            const pct = net.activeWifiNetwork
                ? Math.round(net.activeWifiNetwork.signalStrength * 100) : 0
            raw = "\uf1eb " + pct + "%"
        } else {
            // format-disconnected: xmark glyph, space, warning sign.
            raw = "\uf00d \u26a0"
        }
        // max-length: 50, applied to the whole rendered label same as Waybar.
        return raw.length > 50 ? raw.substring(0, 50) : raw
    }

    // #network.disconnected -> Theme.error, but hover still has to win - that is
    // exactly what BarButton's `hovered` alias exists for.
    contentColor: net.hovered
        ? Theme.primary
        : (net.disconnected ? Theme.error : Theme.on_surface)

    Behavior on contentColor {
        ColorAnimation { duration: 300; easing.type: Easing.OutQuad }
    }

    onClicked: Quickshell.execDetached(["qs", "ipc", "call", "network", "toggle"])
    onRightClicked: Quickshell.execDetached(["sh", "-c", "nm-connection-editor"])
    onMiddleClicked: Quickshell.execDetached(
        ["sh", "-c", "~/.config/ml4w/settings/networkmanager.sh"])
}
