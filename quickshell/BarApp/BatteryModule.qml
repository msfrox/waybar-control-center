// Waybar's `battery` module, ported to Quickshell/UPower.
//
// Cross-checked byte-for-byte against the live config (~/.config/waybar/
// modules.json) rather than retyped from a markdown transcript, because the
// private-use Font Awesome codepoints involved render as nothing in most
// fonts and are silently lost by any copy through plain text:
//
//   "states": { "good": 75, "warning": 30, "critical": 15 }
//   "format":          "{icon} {capacity}%"           (icon = one of the five below)
//   "format-charging": "<bolt>  {capacity}%"          (fa-bolt, then TWO spaces)
//   "format-plugged":  "<plug>  {capacity}%"          (fa-plug, then TWO spaces)
//   "format-icons":    [empty, quarter, half, three-quarters, full]  (fa-battery-*)
//
// `good` and `warning` have no corresponding CSS rules in this theme, so
// unlike `critical` they need no code here at all - noted so the next reader
// does not go looking for one.
//
// Data comes from Quickshell.Services.UPower's display device, same as the
// donor ~/.config/quickshell/StatusbarApp/BatteryModule.qml - that file's API
// usage is reused, its look (SVG icon, accent colour, always-on) is not.

import Quickshell
import Quickshell.Services.UPower
import QtQuick
import qs.CustomTheme

BarButton {
    id: battery

    // Bare module (transparent, no pill) - resolved CSS values for #battery.
    labelSize: 16
    rightMargin: 16

    readonly property var device: UPower.displayDevice
    // Sole condition for showing the module at all - a desktop reports no
    // laptop battery and the module vanishes, same as Waybar's own preview
    // property (deliberately not ported: this is the final implementation).
    readonly property bool hasBattery: battery.device !== null
        && battery.device.isLaptopBattery && battery.device.isPresent
    readonly property int capacity: battery.device
        ? Math.round(battery.device.percentage * 100) : 0
    readonly property bool charging: battery.device !== null
        && battery.device.state === UPowerDeviceState.Charging
    // format-plugged: an adapter is connected but the battery is not
    // actively charging - i.e. topped off/full, not "on battery".
    readonly property bool pluggedNotCharging: battery.hasBattery
        && !UPower.onBattery && !battery.charging
    // "critical" per the states block: capacity <= 15 and not charging - a
    // charging battery under 15% still shows the charging format/colour, not
    // the critical blink, same as `#battery.critical:not(.charging)` in CSS.
    readonly property bool critical: battery.hasBattery
        && battery.capacity <= 15 && !battery.charging

    visible: battery.hasBattery

    // format-icons: empty -> full, same clamp(floor(capacity*N/100)) rule as
    // the volume module, N = 5 here.
    readonly property var capacityIcons: [
        "\uf244", // fa-battery-empty
        "\uf243", // fa-battery-quarter
        "\uf242", // fa-battery-half
        "\uf241", // fa-battery-three-quarters
        "\uf240"  // fa-battery-full
    ]
    readonly property string levelIcon: {
        const n = battery.capacityIcons.length
        const idx = Math.max(0, Math.min(n - 1, Math.floor(battery.capacity * n / 100)))
        return battery.capacityIcons[idx]
    }

    label: {
        if (battery.charging)
            // format-charging: fa-bolt, TWO spaces before the percentage.
            return "\uf5e7  " + battery.capacity + "%"
        if (battery.pluggedNotCharging)
            // format-plugged: fa-plug, TWO spaces before the percentage.
            return "\uf1e6  " + battery.capacity + "%"
        // format: plain level icon, one space, percentage.
        return battery.levelIcon + " " + battery.capacity + "%"
    }

    // No #battery:hover rule in this theme - unlike volume/network, hovering
    // must NOT recolour it, so contentColor drops BarButton's default
    // hover-to-primary behaviour entirely.
    //
    // #battery.critical:not(.charging) blinks between @error and @error at
    // 35% alpha, 0.5s each way, linear, forever - `animation: blink 0.5s
    // linear infinite alternate`. A SequentialAnimation on a 0-1 alpha
    // property reproduces "alternate" (play forward, then backward, repeat)
    // more directly than two independent color animations would.
    property real criticalAlpha: 1.0
    SequentialAnimation {
        running: battery.critical
        loops: Animation.Infinite
        NumberAnimation {
            target: battery; property: "criticalAlpha"
            from: 1.0; to: 0.35; duration: 500; easing.type: Easing.Linear
        }
        NumberAnimation {
            target: battery; property: "criticalAlpha"
            from: 0.35; to: 1.0; duration: 500; easing.type: Easing.Linear
        }
    }
    contentColor: battery.critical
        ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, battery.criticalAlpha)
        : Theme.on_surface

    // Read-only indicator: no click action at all, left/right/middle unbound.
}
