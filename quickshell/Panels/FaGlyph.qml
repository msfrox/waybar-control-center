// A Font Awesome glyph, at weight 900.
//
// The weight is the entire point of this component existing. Four of the glyphs
// this desktop leans on — U+F6A9 (volume muted), U+F796 (network wired),
// U+F5E7 (charging bolt) and U+F590 (headset) — exist in exactly one installed
// face, Font Awesome 7 Free Solid-900. Asking for the family alone lets
// fontconfig resolve it to a Regular-400 face that genuinely lacks them, and
// they render as tofu. Every place that draws one has to say 900 explicitly;
// this is that place.
//
// Defaults to the dim on-surface shade rather than the accent, because in
// practice these are row markers next to text rather than the subject of a row.
// Set `color: PanelStyle.textAccent` where the glyph IS the subject.

import QtQuick
import qs.Panels

Text {
    font.family: PanelStyle.faFamily
    font.weight: PanelStyle.faWeight
    font.pixelSize: PanelStyle.fsBody
    color: PanelStyle.textDim
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
}
