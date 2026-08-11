// Waybar's `pulseaudio` module, ported to Quickshell/Pipewire.
//
// Waybar's own config (~/.config/waybar/modules.json) is the source of truth
// for the exact strings below - copying the private-use Font Awesome
// codepoints out of a chat transcript or a markdown file loses them (they
// render as nothing in most fonts), so this was cross-checked byte-for-byte
// against the live config rather than retyped from memory:
//
//   "format":                "{icon}  {volume}%"
//   "format-muted":          "\uf6a9"
//   "format-bluetooth":      "{volume}% \uf294{icon}"
//   "format-bluetooth-muted":"\uf6a9 \uf294{icon}"
//   "format-icons": { "default": ["\uf026", "\uf028", "\uf028"] }
//
// Notably format-bluetooth-muted still substitutes {icon} (the ordinary
// volume-level glyph) after the mute/Bluetooth glyphs - Waybar has no
// separate "muted" key in format-icons, so {icon} always resolves to the
// current level regardless of mute state. Reproduced as-is.
//
// Volume and mute come from Quickshell.Services.Pipewire rather than
// shelling out to wpctl/pactl, same as AudioApp/AudioWindow.qml. The same
// PwObjectTracker requirement applies here: a PwNode's `audio` member (and
// its `properties`, which the Bluetooth check below reads) stays null/empty
// until something declares interest in that node, so the default sink has
// to be tracked here too rather than assumed to be already tracked by
// AudioWindow - that window may not be loaded when this module is.

import Quickshell
import Quickshell.Services.Pipewire
import QtQuick
import qs.CustomTheme

BarButton {
    id: volume

    // Bare module (transparent, no pill) - resolved CSS values for #pulseaudio.
    labelSize: 16
    rightMargin: 14

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var audio: volume.sink ? volume.sink.audio : null
    readonly property bool muted: volume.audio ? volume.audio.muted : false
    readonly property int volumePercent: volume.audio ? Math.round(volume.audio.volume * 100) : 0

    // See header: without this, volume/muted read zero forever and
    // `sink.properties` (needed for the Bluetooth check) never populates.
    PwObjectTracker {
        objects: volume.sink ? [volume.sink] : []
    }

    // Waybar's own bluetooth detection lives in wireplumber/pipewire-land, not
    // in the module config, so there is no config string to copy here. The
    // reliable marker WirePlumber's bluez5 backend sets is `device.api:
    // bluez5` on the node's properties; fall back to the node name, which for
    // every bluez5 sink is shaped "bluez_output.XX_XX_XX_XX_XX_XX.N", for the
    // rare case a property is missing.
    readonly property bool isBluetooth: {
        if (!volume.sink) return false
        const props = volume.sink.properties
        if (props && props["device.api"] === "bluez5") return true
        const name = (volume.sink.name || "").toLowerCase()
        return name.includes("bluez") || name.includes("bluetooth")
    }

    // No default sink -> nothing to show, same as Waybar dropping the module
    // when pulseaudio reports no sink.
    visible: volume.sink !== null

    // VOLUME LEVEL ICON.
    //
    // DELIBERATE DEVIATION from Waybar, at the owner's request. Waybar's array is
    // ["\uf026", "\uf028", "\uf028"] - the middle and top steps are the same glyph,
    // so its three-step array only ever shows two distinct pictures.
    //
    // The ask was a four-step ramp (no wave / one / two / three) at 25/50/75. Three
    // steps is the most that can be drawn: NEITHER Font Awesome NOR Material Design
    // Icons has a three-wave speaker - both stop at two. Rendered and checked rather
    // than assumed; fa-volume-high and mdi-volume-high are both two arcs. So the
    // bands are the owner's first two boundaries, with the top one running to 100.
    readonly property string levelIcon: {
        const v = volume.volumePercent
        if (v <= 25) return "\uf026"   // fa-volume-off:  bare speaker, no waves
        if (v <= 50) return "\uf027"   // fa-volume-low:  one wave
        return "\uf028"                 // fa-volume-high: two waves
    }

    // PORT ICON.
    //
    // format-icons also has per-port keys, and they are not decorative: with these
    // Bluetooth earbuds as the default sink Waybar shows a headset rather than a
    // speaker, and when a port icon hits it REPLACES the level icon entirely - so a
    // headset never indicates volume by its glyph.
    //
    // Waybar reads PulseAudio's active port ("headset-output") and the device's
    // `device.form_factor` ("headset"). Neither is reachable here: a PwNode's
    // `properties` carries only the node's own keys, and both of those live on the
    // DEVICE. Enumerated at runtime to be sure - the sink exposes api.bluez5.*,
    // device.api, device.id, media.class and node.* , and no form factor.
    //
    // So this keys off `device.api == "bluez5"`, which IS on the node. The
    // limitation that buys: a Bluetooth SPEAKER would also be drawn as a headset.
    // Accepted knowingly - every Bluetooth sink this machine has is worn on a head,
    // and the alternative is resolving device.id against the device list on every
    // change for a glyph.
    readonly property string portIcon:
        volume.isBluetooth ? "\uf590" : ""   // fa-headset

    // What {icon} resolves to: the port icon when the sink has one, else the level.
    readonly property string icon: volume.portIcon !== "" ? volume.portIcon
                                                          : volume.levelIcon

    label: {
        if (volume.muted) {
            if (volume.isBluetooth)
                // format-bluetooth-muted: "\uf6a9 \uf294{icon}"
                return "\uf6a9 \uf294" + volume.icon
            // format-muted: volume-xmark alone, no percentage.
            return "\uf6a9"
        }
        if (volume.isBluetooth)
            // format-bluetooth: "{volume}% \uf294{icon}" - glyph is hardcoded
            // ahead of the level icon, no space between the two.
            return volume.volumePercent + "% \uf294" + volume.icon
        // format: TWO spaces between icon and volume - a literal Waybar quirk,
        // not a typo, so it is kept.
        return volume.icon + "  " + volume.volumePercent + "%"
    }

    // .muted: text at 45% alpha of the normal colour. :hover must still win
    // over muted, which is exactly what `hovered` (BarButton's alias for the
    // MouseArea's containsMouse) is for.
    readonly property color mutedColor: Qt.rgba(
        Theme.on_surface.r, Theme.on_surface.g, Theme.on_surface.b, 0.45)
    contentColor: volume.hovered ? Theme.primary
                                  : (volume.muted ? volume.mutedColor : Theme.on_surface)
    Behavior on contentColor {
        ColorAnimation { duration: 300; easing.type: Easing.OutQuad }
    }

    onClicked: Quickshell.execDetached(["qs", "ipc", "call", "audio", "toggle"])
    onRightClicked: Quickshell.execDetached(["sh", "-c", "pavucontrol"])
}
